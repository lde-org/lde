local ansi = require("ansi")

local lde = require("lde-core")
local resolvePackage = require("lde.util.resolve")

local fs = require("fs")
local path = require("path")
local rocked = require("rocked")

--- Overlapped install for `install rocks:<name>`: the root package's .src.rock
--- starts downloading in the background while its published rockspec (tiny) is
--- fetched and the dependency graph is resolved, so the root download overlaps
--- the dependency install instead of running serially before it.
---@param name string # "rocks:busted" or "rocks:busted@2.0"
local function installRocks(name)
	local download = require("lde-core.util.download")
	local rocksName, versionStr = name:match("^rocks:([^@]+)@?(.*)$")
	versionStr = versionStr ~= "" and versionStr or nil

	-- Metadata-only resolution (URL cache / cached manifest — no network).
	local srcUrl, arch, uerr = lde.util.resolveLuarocksSource(rocksName, versionStr)
	if not srcUrl then error("Failed to resolve '" .. name .. "': " .. (uerr or "")) end

	if arch ~= "src" then
		-- No published .src.rock: classic synchronous path.
		local pkg, perr = lde.util.openLuarocksPackage(rocksName, versionStr)
		if not pkg then error(perr) end
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
		local pkg, perr = lde.util.openLuarocksPackage(rocksName, versionStr)
		if not pkg then error(perr) end
		pkg:build()
		pkg:installDependencies()
		lde.global.writeWrapper(pkg:getName(), nil, name)
		return
	end

	-- Cold install: start the session and kick off the .src.rock download in
	-- the background.
	download.begin()
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
	if not content then error("Failed to fetch rockspec: " .. rockspecUrl) end
	local ok, spec = rocked.parse(content)
	if not ok then error("Failed to parse rockspec '" .. rockspecUrl .. "': " .. tostring(spec)) end

	-- Open the package from the cached rockspec; its source dir is materialized
	-- by the rootExtract hook inside installDependencies once the content batch
	-- has drained (the .src.rock finished downloading long before then). deps
	-- are read from the package (isRoot install, so the .installed fast path
	-- applies on warm trees).
	local pkgDir = path.join(archiveDir, spec.package or rocksName)
	local pkg, perr = lde.Package.openRockspec(pkgDir, rockspecUrl)
	if not pkg then error(perr) end

	pkg:installDependencies(nil, nil, nil, {
		rootExtract = function()
			download.waitBackground(archiveFile)
			local ok2, e2 = lde.global.extractArchive(srcUrl, archiveFile, archiveDir)
			if not ok2 then
				error("Failed to extract '" .. srcUrl .. "': " .. (e2 or "unknown error"))
			end
		end,
	})

	pkg:build()
	lde.global.writeWrapper(pkg:getName(), nil, name)

	download.finish()
end

---@param args clap.Args
local function install(args)
	-- No flags and no name = install deps for current project
	if not args:option("git") and not args:option("path") and not args:peek() then
		local pkg, err = lde.Package.open()
		if not pkg then
			ansi.printf("{red}%s", err)
			return
		end

		local start = ansi.now()
		local opts = { summary = true }

		local runtime, dev
		local ok, installErr = pcall(function()
			runtime = pkg:installDependencies(nil, nil, nil, opts)
			dev = not args:flag("production") and pkg:installDevDependencies(opts)
		end)
		if not ok then
			-- Strip the bundled "file:line: " prefixes the error() calls add.
			ansi.printf("{red}%s", tostring(installErr):gsub('%[string "[^"]+"%]:%d+: ', ""))
			os.exit(1)
		end

		if (runtime and runtime.changed) or (dev and dev.changed) then
			ansi.printf("{green}All dependencies installed successfully.")
		else
			local installs = (runtime and runtime.installs or 0) + (dev and dev.installs or 0)
			local checked = (runtime and runtime.checked or 0) + (dev and dev.checked or 0)
			if checked > 0 then
				local cached = runtime and runtime.cached
				local format = cached
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

	local pkg, err = resolvePackage(args)
	if not pkg then error(err) end

	pkg:build()
	pkg:installDependencies()

	if name and name:match("^rocks:") then
		lde.global.writeWrapper(pkg:getName(), nil, name)
	else
		lde.global.writeWrapper(pkg:getName(), pkg.dir, pkg:getName())
	end
end

return install
