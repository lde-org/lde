local fs = require("fs")
local path = require("path")
local ansi = require("ansi")
local json = require("json")
local util = require("util")
local lde = require("lde-core")
local teal = require("lde-core.teal")
local moonscript = require("lde-core.moonscript")

---@type table<lde.Package, boolean>
local currentlyBuilding = setmetatable({}, { __mode = "k" })
---@type table<string, boolean>
local alreadyBuilt = {}

-- Stamp file written inside the build output dir. It records the size, mtime,
-- and fnv1a hash of every build input (everything under src/, plus lde.json and
-- build.lua) so the build script can be skipped on the next run when none of
-- the inputs changed.
local STAMP_FILE = ".lde-build-stamp"
local STAMP_VERSION = 1

---Build inputs for a package: everything under src/, plus the config and build.lua.
---@param package lde.Package
---@return table<string, string> relative path -> absolute path
local function collectInputFiles(package)
	local inputs = {}
	local srcDir = package:getSrcDir()
	if fs.isdir(srcDir) then
		for _, rel in ipairs(fs.scan(srcDir, "**")) do
			inputs["src/" .. rel:gsub("\\", "/")] = path.join(srcDir, rel)
		end
	end
	inputs[path.basename(package:getConfigPath())] = package:getConfigPath()
	inputs["build.lua"] = package:getBuildScriptPath()
	return inputs
end

---@param stampPath string
---@return table<string, { size: number, mtime: number, hash: string }>
local function readStamp(stampPath)
	local content = fs.read(stampPath)
	if not content then return {} end
	local ok, decoded = pcall(json.decode, content)
	if not ok or type(decoded) ~= "table" or decoded.version ~= STAMP_VERSION or type(decoded.files) ~= "table" then
		return {}
	end
	return decoded.files
end

---Compares the package's inputs against the stored stamp. Any file whose size or
---mtime changed is re-hashed; a differing hash (or a new/removed file) marks the
---build as stale. Returns whether the build must run and the current per-file
---state to persist afterwards.
---@param package lde.Package
---@param stampPath string
---@return boolean changed
---@return table<string, { size: number, mtime: number, hash: string }> current
local function checkInputs(package, stampPath)
	local stored = readStamp(stampPath)
	local current = {}
	local changed = false

	for relPath, absPath in pairs(collectInputFiles(package)) do
		local stat = fs.stat(absPath)
		if not stat then
			changed = true
			goto continue
		end

		-- fs.stat returns ffi cdata for these fields; coerce to plain numbers.
		local size, mtime = tonumber(stat.size), tonumber(stat.modifyTime)
		local prev = stored[relPath]
		if prev and prev.size == size and prev.mtime == mtime then
			-- Fast path: size + mtime unchanged, the stored hash is still valid.
			current[relPath] = prev
		else
			local content = fs.read(absPath)
			if not content then
				changed = true
				goto continue
			end
			local hash = util.fnv1a(content)
			changed = changed or not prev or prev.hash ~= hash
			current[relPath] = { size = size, mtime = mtime, hash = hash }
		end

		::continue::
	end

	-- Files that were inputs to the last build but no longer exist.
	for relPath in pairs(stored) do
		if not current[relPath] then
			changed = true
		end
	end

	return changed, current
end

---@param package lde.Package
---@param destinationPath string?
---@return boolean built # true when a build script actually ran (and finished)
---@return (fun(): boolean?, string?)? deferred # finalizer for async native builds (rockspec builtin with spawned gcc)
local function buildPackage(package, destinationPath)
	if currentlyBuilding[package] then return false end
	currentlyBuilding[package] = true

	destinationPath = destinationPath or path.join(package:getModulesDir(), package:getName())

	local target = path.dirname(destinationPath)
	if not fs.isdir(target) then fs.mkdir(target) end

	---@type (fun(): boolean?, string?)?
	local deferred = nil
	-- Default to "changed" (build must run): rockspec packages have no
	-- build.lua, so checkInputs never runs and their buildfn gates on its own
	-- .lde-built stamp instead.
	local inputsChanged = true
	local built = false

	if package:hasBuildScript() then
		-- If a symlink exists from a previous no-build-script run, remove it
		-- before the build script tries to write into destinationPath as a dir.
		if fs.islink(destinationPath) then fs.delete(destinationPath) end

		-- Skip re-running the build script when none of its inputs changed.
		-- Rockspec packages (buildfn) manage their own .lde-built stamp instead.
		local stampPath = path.join(destinationPath, STAMP_FILE)
		local current = nil
		if fs.exists(package:getBuildScriptPath()) then
			inputsChanged, current = checkInputs(package, stampPath)
		end

		if inputsChanged then
			local alreadyDone = alreadyBuilt[destinationPath] or fs.exists(path.join(destinationPath, ".lde-built"))
			local p = (lde.verbose and not alreadyDone) and ansi.progress("Building " .. package:getName()) or nil
			local ok, err, asyncFinalizer = package:runBuildScript(destinationPath)
			if not ok and not asyncFinalizer then
				if p then p:fail("Building " .. package:getName()) end
				error("Build script failed for package '" .. package:getName() .. "': " .. err)
			end
			if p and not asyncFinalizer then p:done("Built " .. package:getName()) end
			deferred = asyncFinalizer
			built = true
			alreadyBuilt[destinationPath] = true
		end

		-- Record the input state after a successful build (or a confirmed
		-- no-change run) so the next build can skip.
		if current then
			fs.write(stampPath, json.encode({ version = STAMP_VERSION, files = current }))
		end
	else
		-- Clear any previous output (symlink from a no-build-script run, or a
		-- real dir from a build-script/Teal run) before materializing fresh.
		if fs.islink(destinationPath) then
			fs.delete(destinationPath)
		elseif fs.isdir(destinationPath) then
			fs.rmdir(destinationPath)
		end
		if teal.hasTeal(package:getSrcDir()) then
			-- Teal package: compile .tl sources to .lua instead of symlinking,
			-- so the rest of the pipeline (run/test/compile/bundle) only sees Lua.
			teal.compileDir(package:getSrcDir(), destinationPath)
		elseif moonscript.hasMoon(package:getSrcDir()) then
			moonscript.compileDir(package:getSrcDir(), destinationPath)
		else
			fs.mklink(package:getSrcDir(), destinationPath)
		end
	end

	currentlyBuilding[package] = nil
	return built, deferred
end

return buildPackage
