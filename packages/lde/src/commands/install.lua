local ansi = require("ansi")

local lde = require("lde-core")
local resolvePackage = require("lde.util.resolve")

local fs = require("fs")
local path = require("path")
local json = require("json")
local rocked = require("rocked")

-- Resolution inputs for `rocks:` lookups. The resolved URL is a pure function
-- of these two files (the URL cache for unversioned names, the manifest for
-- versioned ones), so the receipt can vouch for "the resolution is unchanged"
-- by comparing their mtimes instead of re-resolving.
local URL_CACHE_PATH = path.join(lde.global.getUserDir(), "luarocks-url-cache-5.1.json")
local MANIFEST_PATH = path.join(lde.global.getUserDir(), "luarocks-manifest.raw")

-- stat().modifyTime is an int64 cdata; normalize to a Lua number so the
-- receipt survives json.encode/decode round-trips.
---@param stat table?
---@return number
local function statMtime(stat)
	return stat and tonumber(stat.modifyTime) or 0
end

--- Per-tree install receipt for `install rocks:<name>`: a small JSON sidecar
--- proving that a specific resolved version is already installed and intact.
--- Written after a successful full install, so later invocations of the same
--- name/version can skip the open/parse/build/install work entirely. The check
--- mirrors the install fast path's `.installed` hash plus isInstallIntact's
--- materialization test, but reads only the receipt + a few stat calls instead
--- of opening and parsing the package.
---@param rocksName string
---@return string
local function rocksReceiptPath(rocksName)
	return path.join(lde.global.getDir(), "rocks-installed", rocksName .. ".json")
end

--- Whether the receipt proves `rocks:<name>` is already installed and intact.
---@param rocksName string
---@return boolean
local function isRocksInstalled(rocksName)
	local receiptPath = rocksReceiptPath(rocksName)
	if not fs.exists(receiptPath) then return false end

	-- decodeJson returns (decoded, err) — the value is the first return.
	local decoded = lde.util.decodeJson(fs.read(receiptPath) or "")
	if type(decoded) ~= "table" then return false end
	local receipt = decoded
	if type(receipt.modulesDir) ~= "string" then return false end
	if receipt.runtime ~= lde.global.currentVersion then return false end
	if receipt.targetKey ~= lde.global.getTargetKey() then return false end

	-- Pre-resolution gate: the resolution result is unchanged only while the
	-- URL cache and manifest files are the ones the install resolved against.
	-- Both live in the user dir (shared across trees), so this is what makes
	-- the skip safe without calling resolveLuarocksSource at all.
	local cacheStat = fs.stat(URL_CACHE_PATH)
	local manifestStat = fs.stat(MANIFEST_PATH)
	if not cacheStat or not manifestStat then return false end
	if receipt.cacheMtime ~= statMtime(cacheStat) then return false end
	if receipt.manifestMtime ~= statMtime(manifestStat) then return false end

	-- The .installed marker only proves the lockfile/manifest/runtime/target
	-- didn't change; verify the file still matches what the receipt recorded,
	-- and that every dependency alias is still materialized (mirrors
	-- isInstallIntact, which also checks path deps with build.lua — impossible
	-- for rocks installs, whose deps are rocks/git/archive).
	if fs.read(path.join(receipt.modulesDir, ".installed")) ~= receipt.installedHash then
		return false
	end
	for _, alias in ipairs(receipt.deps or {}) do
		if not fs.exists(path.join(receipt.modulesDir, alias)) then return false end
	end
	-- The wrapper is the install's user-facing artifact; a deleted wrapper
	-- must be rewritten, so a receipt without it doesn't count as installed.
	if not fs.exists(path.join(lde.global.getToolsDir(), receipt.toolName or rocksName)) then
		return false
	end
	return true
end

--- Writes the install receipt for a successful `install rocks:<name>`.
---@param pkg lde.Package
---@param srcUrl string
---@param rocksName string
local function writeRocksReceipt(pkg, srcUrl, rocksName)
	local modulesDir = pkg:getModulesDir()
	-- commitLockfile writes .installed at the end of installDependencies, so
	-- it exists here. Missing marker = the install didn't finish; skip.
	local installedHash = fs.read(path.join(modulesDir, ".installed"))
	if not installedHash then return end

	local deps = {}
	for alias in pairs(pkg:readConfig().dependencies or {}) do
		deps[#deps + 1] = alias
	end

	local cacheStat = fs.stat(URL_CACHE_PATH)
	local manifestStat = fs.stat(MANIFEST_PATH)

	local receipt = {
		srcUrl = srcUrl,
		runtime = lde.global.currentVersion,
		targetKey = lde.global.getTargetKey(),
		cacheMtime = statMtime(cacheStat),
		manifestMtime = statMtime(manifestStat),
		modulesDir = modulesDir,
		installedHash = installedHash,
		toolName = pkg:getName(),
		deps = deps,
	}
	fs.mkdirAll(path.dirname(rocksReceiptPath(rocksName)))
	fs.write(rocksReceiptPath(rocksName), json.encode(receipt))
end

--- Overlapped install for `install rocks:<name>`: the root package's .src.rock
--- starts downloading in the background while its published rockspec (tiny) is
--- fetched and the dependency graph is resolved, so the root download overlaps
--- the dependency install instead of running serially before it.
---@param name string # "rocks:busted" or "rocks:busted@2.0"
local function installRocks(name)
	local download = require("lde-core.util.download")
	local rocksName, versionStr = name:match("^rocks:([^@]+)@?(.*)$")
	versionStr = versionStr ~= "" and versionStr or nil

	-- Fast path: the receipt proves this exact resolution is already
	-- installed and intact (its URL-cache/manifest mtimes guarantee the
	-- resolution is unchanged), so skip everything — including the resolve.
	if isRocksInstalled(rocksName) then
		return
	end

	-- Metadata-only resolution (URL cache / cached manifest — no network).
	local srcUrl, arch, uerr = lde.util.resolveLuarocksSource(rocksName, versionStr)
	if not srcUrl then
		lde.error.raise("Failed to resolve '" .. name .. "': " .. (uerr or ""), { hint = lde.util.suggestPackage(rocksName, true) })
	end ---@cast srcUrl -nil

	if arch ~= "src" then
		-- No published .src.rock: classic synchronous path.
		local pkg, _, perr = lde.util.openLuarocksPackage(rocksName, versionStr)
		if not pkg then lde.error.raise(perr or "Failed to open package") end ---@cast pkg -nil
		pkg:build()
		pkg:installDependencies()
		lde.global.writeWrapper(pkg:getName(), nil, name)
		return
	end

	local archiveDir = lde.global.getArchiveDir(srcUrl)
	local archiveFile = archiveDir .. ".archive"

	if fs.exists(archiveDir) then
		-- Already materialized: classic path, which hits the install fast path
		-- (few ms on a warm tree).
		local pkg, _, perr = lde.util.openLuarocksPackage(rocksName, versionStr)
		if not pkg then lde.error.raise(perr or "Failed to open package") end ---@cast pkg -nil
		pkg:build()
		pkg:installDependencies()
		writeRocksReceipt(pkg, srcUrl, rocksName)
		lde.global.writeWrapper(pkg:getName(), nil, name)
		return
	end

	-- Cold install: start the session and kick off the .src.rock download in
	-- the background. The archive cache seeds already-downloaded content so a
	-- fresh tree doesn't re-fetch bytes a previous tree already fetched.
	download.begin({
		archiveCache = path.join(lde.global.getUserDir(), "archives"),
	})
	download.background(srcUrl, archiveFile)

	-- The published rockspec is tiny; wait only for it, then resolve deps while
	-- the .src.rock keeps downloading.
	local rockspecUrl = srcUrl:gsub("%.src%.rock$", ".rockspec")
	local rockspecFile = lde.util.rockspecCacheFile(rockspecUrl)
	local content
	if fs.exists(rockspecFile) then
		content = fs.read(rockspecFile)
	else
		download.prefetch(rockspecUrl, rockspecFile)
		download.drain()
		content = fs.read(rockspecFile)
	end
	if not content then lde.error.raise("Failed to fetch rockspec: " .. rockspecUrl) end ---@cast content -nil
	local ok, spec = rocked.parse(content)
	if not ok then lde.error.raise("Failed to parse rockspec '" .. rockspecUrl .. "': " .. tostring(spec)) end

	-- Wait for the .src.rock download, then extract it and open the package
	-- from the real source tree inside (a source subdir, or the nested archive
	-- extracted alongside the rockspec). The package must be opened from that
	-- tree: dependencies install into the package's target/ and bin scripts are
	-- copied from the sources, so building from a made-up directory would
	-- silently produce an empty install with no bin.
	download.waitBackground(archiveFile)
	local exOk, exErr = lde.global.extractArchive(srcUrl, archiveFile, archiveDir)
	if not exOk then
		lde.error.raise("Failed to extract '" .. srcUrl .. "': " .. (exErr or "unknown error"))
	end

	local pkg, perr = lde.util.openSrcRock(archiveDir, srcUrl)
	if not pkg then lde.error.raise(perr or "Failed to load package") end ---@cast pkg -nil

	pkg:installDependencies()
	pkg:build()
	writeRocksReceipt(pkg, srcUrl, rocksName)
	lde.global.writeWrapper(pkg:getName(), nil, name)

	download.finish()
end

---@param args clap.Args
local function install(args)
	-- The option() calls consume their values; capture them up front so the
	-- project-install check and resolvePackage can both see them.
	local gitUrl = args:option("git")
	local pathDir = args:option("path")

	-- No flags and no name = install deps for current project
	if not gitUrl and not pathDir and not args:peek() then
		local pkg, err = lde.Package.open()
		if not pkg then
			lde.error.raise(err)
		end ---@cast pkg -nil

		local start = ansi.now()
		local opts = { summary = true }

		-- Errors propagate to the CLI boundary, which renders them cleanly.
		local runtime = pkg:installDependencies(nil, nil, nil, opts)
		local dev = not args:flag("production") and pkg:installDevDependencies(opts)

		if (runtime and runtime.hasChanged) or (dev and dev.hasChanged) then
			ansi.printf("{green}All dependencies installed successfully.")
		else
			local installs = (runtime and runtime.installs or 0) + (dev and dev.installs or 0)
			local checked = (runtime and runtime.checked or 0) + (dev and dev.checked or 0)
			if checked > 0 then
				local isCached = runtime and runtime.isCached
				local format = isCached
					and "{gray}No changes in %d %s across %d %s (cached) (%s)"
					or "{gray}No changes in %d %s across %d %s (%s)"
				ansi.printf(format,
					installs, installs == 1 and "install" or "installs",
					checked, checked == 1 and "package" or "packages",
					ansi.formatElapsed(ansi.now() - start))
			end
		end
		return
	end

	local name = args:peek()
	if name and name:match("^rocks:") then
		installRocks(name)
		return
	end

	local pkg, err, hint = resolvePackage(args, { git = gitUrl, path = pathDir })
	if not pkg then lde.error.raise(err, { hint = hint }) end ---@cast pkg -nil

	pkg:build()
	pkg:installDependencies()

	if name and name:match("^rocks:") then
		lde.global.writeWrapper(pkg:getName(), nil, name)
	else
		lde.global.writeWrapper(pkg:getName(), pkg.dir, pkg:getName())
	end
end

return install
