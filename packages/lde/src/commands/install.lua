const ansi = require("ansi")

const lde = require("lde-core")
const resolvePackage = require("lde.util.resolve")

const fs = require("fs")
local path = require("path")
const json = require("json")
const rocked = require("rocked")

-- The resolved URL is a pure function of these two files, so compare their mtimes instead of re-resolving.
const URL_CACHE_PATH = path.join(lde.global.getUserDir(), "luarocks-url-cache-5.1.json")
const MANIFEST_PATH = path.join(lde.global.getUserDir(), "luarocks-manifest.raw")

-- modifyTime is int64 cdata; normalize so the receipt survives json round-trips.
---@param stat table?
---@return number
local function statMtime(stat)
	return stat and tonumber(stat.modifyTime) or 0
end

--- Sidecar proving a resolved rocks version is installed, so later runs can skip the install.
---@param rocksName string
local function rocksReceiptPath(rocksName)
	return path.join(lde.global.getDir(), "rocks-installed", rocksName .. ".json")
end

---@param rocksName string
---@return boolean
local function isRocksInstalled(rocksName)
	const receiptPath = rocksReceiptPath(rocksName)
	if not fs.exists(receiptPath) then return false end

	local decoded = lde.util.decodeJson(fs.read(receiptPath) or "")
	if type(decoded) ~= "table" then return false end
	local receipt = decoded
	if type(receipt.modulesDir) ~= "string" then return false end
	if receipt.runtime ~= lde.global.currentVersion then return false end
	if receipt.targetKey ~= lde.global.getTargetKey() then return false end

	-- Safe only while the shared user-dir URL cache and manifest are the ones resolved against.
	local cacheStat = fs.stat(URL_CACHE_PATH)
	local manifestStat = fs.stat(MANIFEST_PATH)
	if not cacheStat or not manifestStat then return false end
	if receipt.cacheMtime ~= statMtime(cacheStat) then return false end
	if receipt.manifestMtime ~= statMtime(manifestStat) then return false end

	-- .installed covers only lockfile/manifest/runtime/target; also verify the modules dir and aliases.
	if fs.read(path.join(receipt.modulesDir, ".installed")) ~= receipt.installedHash then
		return false
	end
	for _, alias in ipairs(receipt.deps or {}) do
		if not fs.exists(path.join(receipt.modulesDir, alias)) then return false end
	end
	-- A deleted wrapper must be rewritten, so a receipt without it isn't installed.
	if not fs.exists(path.join(lde.global.getToolsDir(), receipt.toolName or rocksName)) then
		return false
	end
	return true
end

---@param pkg lde.Package
---@param srcUrl string
---@param rocksName string
local function writeRocksReceipt(pkg, srcUrl, rocksName)
	local modulesDir = pkg:getModulesDir()
	-- .installed is written at the end of installDependencies; a missing marker means it didn't finish.
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

-- Starts the .src.rock download while the small rockspec is fetched and deps resolved.
---@param name string # "rocks:busted" or "rocks:busted@2.0"
local function installRocks(name)
	local download = require("lde-core.util.download")
	local rocksName, versionStr = name:match("^rocks:([^@]+)@?(.*)$")
	versionStr = versionStr ~= "" ? versionStr : nil

	-- Receipt proves this exact resolution is installed and intact, so skip everything.
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
		-- Already materialized: classic path, a few ms on a warm tree.
		local pkg, _, perr = lde.util.openLuarocksPackage(rocksName, versionStr)
		if not pkg then lde.error.raise(perr or "Failed to open package") end ---@cast pkg -nil
		pkg:build()
		pkg:installDependencies()
		writeRocksReceipt(pkg, srcUrl, rocksName)
		lde.global.writeWrapper(pkg:getName(), nil, name)
		return
	end

	-- Archive cache seeds already-downloaded content so a fresh tree doesn't re-fetch.
	download.begin({
		archiveCache = path.join(lde.global.getUserDir(), "archives"),
	})
	download.background(srcUrl, archiveFile)

	-- The published rockspec is tiny; wait only for it, then resolve deps while
	-- the .src.rock keeps downloading.
	local rockspecUrl = srcUrl:gsub("%.src%.rock$", ".rockspec")
	const rockspecFile = lde.util.rockspecCacheFile(rockspecUrl)
	local content
	if fs.exists(rockspecFile) then
		content = fs.read(rockspecFile)
	else
		download.prefetch(rockspecUrl, rockspecFile)
		download.drain()
		content = fs.read(rockspecFile)
	end
	if not content then lde.error.raise("Failed to fetch rockspec: " .. rockspecUrl) end ---@cast content -nil
	const ok, spec = rocked.parse(content)
	if not ok then lde.error.raise("Failed to parse rockspec '" .. rockspecUrl .. "': " .. tostring(spec)) end

	-- Open from the extracted source tree: deps install into its target/ and bins come from its sources.
	download.waitBackground(archiveFile)
	const exOk, exErr = lde.global.extractArchive(srcUrl, archiveFile, archiveDir)
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
	-- option() consumes values; capture them before resolvePackage and --production read.
	local gitUrl = args:option("git")
	const pathDir = args:option("path")
	const isProduction = args:flag("production")

	if not gitUrl and not pathDir and not args:peek() then
		local pkg, err = lde.Package.open()
		if not pkg then
			lde.error.raise(err)
		end ---@cast pkg -nil

		const start = ansi.now()
		const opts = { summary = true }

		-- Errors propagate to the CLI boundary, which renders them cleanly.
		const runtime = pkg:installDependencies(nil, nil, nil, opts)
		const dev = isProduction ? nil : pkg:installDevDependencies(opts)

		if (runtime and runtime.hasChanged) or (dev and dev.hasChanged) then
			ansi.printf("{green}All dependencies installed successfully.")
		else
			local installs = (runtime?.installs ?? 0) + (dev?.installs ?? 0)
			local checked = (runtime?.checked ?? 0) + (dev?.checked ?? 0)
			if checked > 0 then
				const isCached = runtime?.isCached
				local format = isCached
					and "{gray}No changes in %d %s across %d %s (cached) (%s)"
					or "{gray}No changes in %d %s across %d %s (%s)"
				ansi.printf(format,
					installs, installs == 1 ? "install" : "installs",
					checked, checked == 1 ? "package" : "packages",
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
