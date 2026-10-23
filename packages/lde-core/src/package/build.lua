const fs = require("fs")
const path = require("path")
const ansi = require("ansi")
const json = require("json")
const util = require("util")
const process = require("process")
const ffi = require("ffi")
local env = require("env")
const lde = require("lde-core")
const teal = require("lde-core.teal")
const moonscript = require("lde-core.moonscript")
const asyncBuild = require("lde-core.util.async-build")
const buildLog = require("lde-core.util.build-log")

---@type table<lde.Package, boolean>
const currentlyBuilding = setmetatable({}, { __mode = "k" })
const lock = require("lde-core.package.install.lock")
---@type table<string, boolean>
const alreadyBuilt = {}

-- Stamp of every build input (size/mtime/rapidhash of src/, lde.json, build.lua) letting the build script be skipped when none changed; the compile target is part of the stamp, so switching --target rebuilds.
const STAMP_FILE = ".lde-build-stamp"
local STAMP_VERSION = 1

--- Millisecond sleep while waiting for a spawned native compile (fs has no timer).
local sleep
if jit.os == "Windows" then
	pcall(ffi.cdef, "void Sleep(unsigned long dwMilliseconds);")
	sleep = function(ms) ffi.C.Sleep(ms) end
else
	pcall(ffi.cdef, "int usleep(unsigned int usec);")
	sleep = function(ms) ffi.C.usleep(ms * 1000) end
end

---@param package lde.Package
---@return table<string, string> relative path -> absolute path
local function collectInputFiles(package)
	const inputs = {}
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
---@return table<string, { size: number, mtime: number, hash: string }> files
---@return string target # target key the stamp was built for ("" = native)
local function readStamp(stampPath)
	local content = fs.read(stampPath)
	if not content then return {}, "" end
	local ok, decoded = pcall(json.decode, content)
	if not ok or type(decoded) ~= "table" or decoded.version ~= STAMP_VERSION or type(decoded.files) ~= "table" then
		return {}, ""
	end
	return decoded.files, type(decoded.target) == "string" ? decoded.target : ""
end

--- A stored stamp for a different compile target is always stale.
---@param package lde.Package
---@param stampPath string
---@return boolean hasChanged
---@return table<string, { size: number, mtime: number, hash: string }> current
local function checkInputs(package, stampPath)
	const stored, storedTarget = readStamp(stampPath)
	local current = {}
	local hasChanged = storedTarget ~= lde.global.getTargetKey()

	for relPath, absPath in pairs(collectInputFiles(package)) do
		const stat = fs.stat(absPath)
		if not stat then
			hasChanged = true
			goto continue
		end

		-- fs.stat returns ffi cdata for these fields; coerce to plain numbers.
		local size, mtime = tonumber(stat.size), tonumber(stat.modifyTime)
		const prev = stored[relPath]
		if prev and prev.size == size and prev.mtime == mtime then
			current[relPath] = prev
		else
			local content = fs.read(absPath)
			if not content then
				hasChanged = true
				goto continue
			end
			local hash = util.hash(content)
			hasChanged = hasChanged or not prev or prev.hash ~= hash
			current[relPath] = { size = size, mtime = mtime, hash = hash }
		end

		::continue::
	end

	for relPath in pairs(stored) do
		if not current[relPath] then
			hasChanged = true
		end
	end

	return hasChanged, current
end

---@param package lde.Package
---@param destinationPath string?
---@param opts { async: boolean? }? # async: return the deferred native builder (install scheduler only)
---@return boolean hasBuilt # true when a build script actually ran (and finished)
---@return lde.install.DeferredBuild? deferred # finalizer for async native builds (rockspec builtin or a build.lua subprocess)
local function buildPackage(package, destinationPath, opts)
	if currentlyBuilding[package] then return false end
	currentlyBuilding[package] = true

	-- A concurrent cache retirement can remove the source tree between opening the
	-- package and building it. Creating the build lock then recreates an empty
	-- directory under the tar cache, which later resolutions would trust as a
	-- valid cache entry (and fail with "No rockspec found in src rock").
	if not fs.isdir(package:getDir()) then
		currentlyBuilding[package] = nil
		lde.error.raise("Package source directory disappeared while building '"
			.. package:getName() .. "' (concurrent cache cleanup)")
	end

	-- The re-entrancy guard must be cleared even on failure: a leaked guard makes every later build silently no-op (pcall reports the returned false as success).
	-- Serialize builds of the same destination across processes: a cached rock is
	-- built in place under ~/.lde/tar, so a second install (or a second test
	-- shard resolving the same compiler) would otherwise delete the directory the
	-- first is linking into.
	const buildLock = lock.acquire(destinationPath or path.join(package:getModulesDir(), package:getName()))

	local ok, hasBuilt, deferred = xpcall(function()
		-- A parameter with a declared type is not narrowed by assigning to it, so the default must go through a local.
		const dest = destinationPath or path.join(package:getModulesDir(), package:getName())

		local target = path.dirname(dest)
		if not fs.isdir(target) then fs.mkdir(target) end

		---@type lde.install.DeferredBuild?
		local deferred = nil
		-- Rockspec packages have no build.lua, so checkInputs never runs and their buildfn gates on its own .lde-built stamp instead.
		local inputsChanged = true
		local hasBuilt = false

		if package:hasBuildScript() then
		-- Remove a symlink left by a previous no-build-script run before the build script writes into destinationPath as a dir.
		if fs.islink(dest) then fs.delete(dest) end

		local stampPath = path.join(dest, STAMP_FILE)
		local current = nil
		if fs.exists(package:getBuildScriptPath()) then
			inputsChanged, current = checkInputs(package, stampPath)
		end

		if inputsChanged then
			-- build.lua packages are stamped here, so a rebuild starts clean. A
			-- rockspec buildfn is stamped by its own .lde-built check and cleans
			-- its output dir only when it actually rebuilds: deleting it here made
			-- every concurrent build wipe a tree another process was loading, which
			-- surfaced as "invalid ELF header" or a vanished native module.
			if package.buildfn == nil and fs.isdir(dest) then fs.rmdir(dest) end

			-- Key by target too: a cross compile after a native build in the same process must not skip the rebuild.
			const buildKey = dest .. "\n" .. lde.global.getTargetKey()
			const alreadyDone = alreadyBuilt[buildKey] or fs.exists(path.join(dest, ".lde-built"))
			const p = (lde.isVerbose and not alreadyDone) ? ansi.progress("Building " .. package:getName()) : nil
			-- Compact mode: build.lua output is hidden by default and only dumped to a temp file if the build fails (see util/build-log).
			const capture = (not lde.isVerbose) ? buildLog.newCapture() : nil

			-- Stamped after a successful build (or a confirmed no-change run) so the next build can skip; the subprocess path does this in its finalizer after the child exits.
			const writeStamp = function()
				if current then
					fs.write(stampPath, json.encode({
						version = STAMP_VERSION,
						target = lde.global.getTargetKey(),
						files = current,
					}))
				end
			end

			-- A build.lua runs synchronously through os.execute and blocks the host LuaJIT; during the install build pass run it in a subprocess so independent native builds overlap (rockspec buildfn keeps its own async-gcc path).
			if asyncBuild.isActive() and package.buildfn == nil and fs.exists(package:getBuildScriptPath()) then
				local ldeBin = os.getenv("LDE_BIN") or assert(env.execPath(), "no executable path")

				-- CreateProcess (Windows) fails when the cwd doesn't exist, and this is usually the first build: create the output dir up front so the spawn succeeds everywhere.
				if not fs.isdir(dest) then fs.mkdir(dest) end
				const buildTarget = lde.global.getTarget()
				const targetName = buildTarget?.name ?? ""

				-- The worker captures (compact) or streams (verbose, via LDE_VERBOSE) its own output; stdout stays "inherit" since it prints nothing unless verbose, so there is no pipe to deadlock on.
				const child, serr = process.spawn(ldeBin,
					{ "__build-pkg", package:getDir(), dest, targetName },
					-- cwd = dest so the worker's build:sh os.execute calls resolve relative paths against the output dir.
					{
						stdout = "inherit",
						stderr = "inherit",
						cwd = dest,
						env = lde.isVerbose ? { LDE_VERBOSE = "1" } : nil,
					})
				if not child then ---@cast child -nil
				end
				if not child then
					if p then p:fail("Building " .. package:getName()) end
					lde.error.raise("Failed to spawn build worker for '" .. package:getName() .. "': " .. (serr or "spawn failed"))
				end
				hasBuilt = true
				alreadyBuilt[buildKey] = true
				-- child:poll() reaps the process on POSIX, so the exit code must be captured there (a later wait() returns ECHILD with an uninitialized status).
				local exitCode
				deferred = {
					poll = function()
						local code = child:poll()
						if code == nil then return nil end
						exitCode = code
						return true
					end,
					finalize = function()
						local code = exitCode or child:wait()
						if code ~= 0 then
							-- The worker wrote the captured output to the deterministic log path before exiting; read it back so the failure prints the full output.
							local msg = "build worker exited with code " .. tostring(code)
							local logPath = buildLog.pathFor(dest)
							if fs.exists(logPath) then
								local content = fs.read(logPath)
								msg ..= "\n  Full build output at " .. logPath
								if content and content ~= "" then msg ..= "\n\n" .. content end
							end
							return nil, msg
						end
						writeStamp()
						if p then p:done("Built " .. package:getName()) end
						return true
					end,
				}
			else
				local ok, err, asyncFinalizer = package:runBuildScript(dest, capture)
				if not ok and not asyncFinalizer then
					if p then p:fail("Building " .. package:getName()) end
					local msg = "Build script failed for package '" .. package:getName() .. "': " .. lde.error.message(err)
					local logPath = capture ? (capture:write(dest)) : nil
					if logPath then msg ..= "\n  Full build output at " .. logPath end
					local content = capture ? table.concat(capture.parts) : nil
					if content and content ~= "" then msg ..= "\n\n" .. content end
					lde.error.raise(msg)
				end
				if p and not asyncFinalizer then p:done("Built " .. package:getName()) end
				deferred = asyncFinalizer
				hasBuilt = true
				alreadyBuilt[buildKey] = true
				if not asyncFinalizer then writeStamp() end
			end
		end
	else
		if fs.islink(dest) then
			fs.delete(dest)
		elseif fs.isdir(dest) then
			fs.rmdir(dest)
		end
		if teal:hasSource(package:getSrcDir()) then
			-- Teal: compile .tl sources to .lua (instead of symlinking) so the rest of the pipeline only sees Lua.
			teal:compileDir(package:getSrcDir(), dest)
		elseif moonscript:hasSource(package:getSrcDir()) then
			moonscript:compileDir(package:getSrcDir(), dest)
		else
			fs.mklink(package:getSrcDir(), dest)
		end
	end

		return hasBuilt, deferred
	end, e -> e)

	currentlyBuilding[package] = nil
	if not ok then
		lock.release(buildLock)
		error(hasBuilt, 0)
	end
	if deferred then
		-- Deferred native compiles still write into the destination: hold the lock
		-- until the caller finalizes them.
		const finalize = deferred.finalize
		deferred.finalize = function()
			const finalized, ferr = finalize()
			lock.release(buildLock)
			return finalized, ferr
		end
		-- Only the install scheduler overlaps builds; every other caller reads the
		-- tree right after, so it must wait for the linker instead of racing it.
		if opts?.async then return hasBuilt, deferred end
		while deferred.poll() == nil do sleep(20) end
		local built, buildErr = deferred.finalize()
		if not built then
			lde.error.raise("Build failed for '" .. package:getName() .. "': " .. tostring(buildErr))
		end
		return hasBuilt, nil
	end
	lock.release(buildLock)
	return hasBuilt, nil
end

--- Used by the install fast path so `lde sync`/`lde run` rebuild a path dep whose source changed even when the root .installed marker still matches (a missing stamp counts as stale).
---@param package lde.Package
---@param dest string
local function isStale(package, dest)
	local stampPath = path.join(dest, STAMP_FILE)
	local hasChanged, _ = checkInputs(package, stampPath)
	return hasChanged
end

---@class lde.packageBuild
---@field build fun(package: lde.Package, destinationPath: string?, opts: { async: boolean? }?): boolean?, lde.install.DeferredBuild?
---@field isStale fun(package: lde.Package, destinationPath: string): boolean

---@type lde.packageBuild
return { build = buildPackage, isStale = isStale }
