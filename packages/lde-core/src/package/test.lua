local fs      = require("fs")
local path    = require("path")
local env     = require("env")
local ffi     = require("ffi")
local lua     = require("lua-sys")
local runtime = require("lde-core.runtime")

---@class lde.TestFileResult
---@field file    string
---@field results lde.test.Result[]
---@field error   string?

---@class lde.TestReporter
---@field onFileStart? fun(file: string)
---@field onFileDone?  fun(file: string)
---@field onStart?     fun(name: string): any
---@field onPass?      fun(name: string, handle: any)
---@field onFail?      fun(name: string, err: string, handle: any)
---@field onSkip?      fun(name: string)

---@class lde.TestResults
---@field package  lde.Package
---@field files    lde.TestFileResult[]
---@field total    number
---@field failures number
---@field skipped  number
---@field error    string?

local function getLuaPathsForPackage(pkg)
	local modulesDir = pkg:getModulesDir()
	local luaPath =
		path.join(modulesDir, "?.lua") .. ";"
		.. path.join(modulesDir, "?", "init.lua") .. ";"
	local luaCPath =
		ffi.os == "Linux"    and path.join(modulesDir, "?.so")    .. ";"
		or ffi.os == "Windows" and path.join(modulesDir, "?.dll")  .. ";"
		or path.join(modulesDir, "?.dylib") .. ";"
	return luaPath, luaCPath
end

-- The lde-test source, loaded once at module load time.
-- It's pure Lua with no external dependencies, so we inject it directly into
-- any guest state. We find it either via package.path (installed as lde-test.test)
-- or directly from the sibling lde-test package in the monorepo.
local ldeTestSource = (function()
	-- Preferred: find via the host's package.path (works in any install context)
	local found = package.searchpath("lde-test.test", package.path)
	if found then
		local src = fs.read(found)
		if src then return src end
	end

	-- Fallback: derive from this file's location in the monorepo.
	-- This file: .../packages/lde-core/src/package/test.lua
	-- lde-test:  .../packages/lde-test/src/test.lua
	local thisFile = debug.getinfo(1, "S").source:sub(2)
	-- Resolve symlinks: the source may be accessed via target/ symlink
	local realFile = fs.realpath and fs.realpath(thisFile) or thisFile
	local ldeCoreSrc  = path.dirname(path.dirname(realFile or thisFile))  -- .../lde-core/src
	local packagesDir = path.dirname(path.dirname(ldeCoreSrc))            -- .../packages
	local candidate   = path.join(packagesDir, "lde-test", "src", "test.lua")
	local src = fs.read(candidate)
	if src then return src end

	error("lde-test source not found — ensure lde-test is installed (lde install in lde-core)")
end)()

--- Run a single test file in a fresh guest state.
--- lde-test runs entirely in the guest; only reporter callbacks cross the boundary
--- (they receive only primitive string arguments).
---
---@param testFile   string
---@param luaPath    string
---@param luaCPath   string
---@param reporter   lde.TestReporter?
---@return lde.TestFileResult
local function runTestFile(testFile, luaPath, luaCPath, reporter)
	local results   = {}
	local handles   = {}   -- name → reporter handle (host-side opaque value)

	-- Reporter callbacks: all args are primitives (strings), safe to cross boundary.
	local onStart = reporter and reporter.onStart and function(name)
		local handle = reporter.onStart(name)
		handles[name] = handle
	end or nil

	local onPass = reporter and reporter.onPass and function(name)
		reporter.onPass(name, handles[name])
		handles[name] = nil
	end or nil

	local onFail = reporter and reporter.onFail and function(name, err)
		reporter.onFail(name, err, handles[name])
		handles[name] = nil
	end or nil

	local onSkip = reporter and reporter.onSkip and function(name)
		reporter.onSkip(name)
	end or nil

	-- Collect results on the host side via a callback the guest calls per result.
	local onResult = function(name, ok, skipped, err)
		if skipped then
			results[#results + 1] = { name = name, ok = true, skipped = true }
		else
			results[#results + 1] = { name = name, ok = ok == true, error = err }
		end
	end

	local source, readErr = fs.read(testFile)
	if not source then
		return { file = testFile, results = {}, error = "Could not read: " .. (readErr or "?") }
	end

	-- Wrap the test file: inject lde-test as a guest-local module, run the file,
	-- then drive instance.run() with reporter callbacks that only pass primitives.
	-- We use concatenation rather than string.format to avoid misinterpreting
	-- % characters in ldeTestSource or the test file source as format directives.
	local escapedSource = string.format("%q", source)
	local wrapper = [[
		local _lde_test_factory = (function()
		]] .. ldeTestSource .. [[
		end)()
		local _lde_test_instance = _lde_test_factory.new()
		package.preload["lde-test"] = function() return _lde_test_instance end
		package.preload["lpm-test"] = function() return _lde_test_instance end
		local _chunk = assert(loadstring(]] .. escapedSource .. [[, ]] .. string.format("%q", "@" .. testFile) .. [[))
		_chunk()
		local _reporter = {}
		if _lde_on_start  then _reporter.onStart  = function(name)         _lde_on_start(name)        end end
		if _lde_on_pass   then _reporter.onPass   = function(name, _)      _lde_on_pass(name)         end end
		if _lde_on_fail   then _reporter.onFail   = function(name, err, _) _lde_on_fail(name, err)    end end
		if _lde_on_skip   then _reporter.onSkip   = function(name)         _lde_on_skip(name)         end end
		local _results = _lde_test_instance.run(_reporter)
		for _, r in ipairs(_results) do
			_lde_on_result(r.name, r.ok == true, r.skipped == true, r.error or "")
		end
	]]

	local globals = {
		_lde_on_result = onResult,
		_lde_on_start  = onStart,
		_lde_on_pass   = onPass,
		_lde_on_fail   = onFail,
		_lde_on_skip   = onSkip,
	}

	local ok, err = runtime.executeString(wrapper, {
		packagePath  = luaPath,
		packageCPath = luaCPath,
		globals      = globals,
	})

	if not ok then
		return { file = testFile, results = {}, error = err }
	end

	return { file = testFile, results = results }
end

---@param package  lde.Package
---@param reporter lde.TestReporter?
---@param filters  string[]?
---@return lde.TestResults
local function runTests(package, reporter, filters)
	package:installDependencies()
	package:installDevDependencies()
	package:build()

	local testDir = package:getTestDir()
	if not fs.exists(testDir) then
		return {
			package  = package,
			files    = {},
			total    = 0,
			failures = 0,
			error    = "No tests directory found in package: " .. testDir
		}
	end

	local luaPath, luaCPath = getLuaPathsForPackage(package)

	-- Expose tests/ via target/tests so test files can require each other
	local targetTestsDir = path.join(package:getModulesDir(), "tests")
	if not fs.exists(targetTestsDir) then
		if package:hasBuildScript() then
			fs.copy(testDir, targetTestsDir)
		else
			fs.mklink(testDir, targetTestsDir)
		end
	end

	local testFiles = fs.scan(testDir, "**" .. path.separator .. "*.test.lua")

	if filters and #filters > 0 then
		for i, filter in ipairs(filters) do
			local first = filter:sub(1, 1)
			if first == "." or first == "/" or (ffi.os == "Windows" and filter:match("^%a:\\")) then
				local resolved = path.resolve(env.cwd(), filter)
				local rel = path.relative(testDir, resolved)
				if rel and not rel:match("^%.%.") then
					filters[i] = rel == "." and "*" or rel
				end
			end
		end
		local filtered = {}
		for _, relPath in ipairs(testFiles) do
			for _, glob in ipairs(filters) do
				if string.find(relPath, fs.globToPattern(glob)) then
					filtered[#filtered + 1] = relPath
					break
				end
			end
		end
		testFiles = filtered
	end

	local files         = {}
	local totalTests    = 0
	local totalFailures = 0
	local totalSkipped  = 0

	for _, relativePath in ipairs(testFiles) do
		local testFile = path.join(testDir, relativePath)

		if reporter and reporter.onFileStart then reporter.onFileStart(relativePath) end

		local fileResult = runTestFile(testFile, luaPath, luaCPath, reporter)
		fileResult.file  = relativePath

		local failCount = 0
		local skipCount = 0
		for _, r in ipairs(fileResult.results) do
			if r.skipped then skipCount = skipCount + 1
			elseif not r.ok then failCount = failCount + 1
			end
		end

		totalTests    = totalTests    + #fileResult.results - skipCount
		totalFailures = totalFailures + failCount
		totalSkipped  = totalSkipped  + skipCount

		files[#files + 1] = fileResult

		if reporter and reporter.onFileDone then reporter.onFileDone(relativePath) end
	end

	return {
		package  = package,
		files    = files,
		total    = totalTests,
		failures = totalFailures,
		skipped  = totalSkipped
	}
end

return runTests
