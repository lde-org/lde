local fs      = require("fs")
local path    = require("path")
local env     = require("env")
local ffi     = require("ffi")
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
		ffi.os == "Linux"   and path.join(modulesDir, "?.so")   .. ";"
		or ffi.os == "Windows" and path.join(modulesDir, "?.dll") .. ";"
		or path.join(modulesDir, "?.dylib") .. ";"
	return luaPath, luaCPath
end

--- Build the lde-test API as a table of host callbacks.
--- `it(name, fn)` and friends push registrations into the returned tables;
--- `fn` values are guest-state callables returned by lua-sys.
---
---@return table   testApi      the table that the guest gets as require("lde-test")
---@return table   registered   { name, fn, skipped }[]  populated when guest runs
---@return table   afterEachFns
---@return table   afterAllFns
local function makeTestApi()
	local registered   = {}
	local afterEachFns = {}
	local afterAllFns  = {}

	local function deepEqualInner(a, b, p)
		if a == b then return end
		if type(a) ~= type(b) then
			error("Expected " .. p .. " to be " .. type(b) .. ", got " .. type(a), 0)
		end
		if type(a) ~= "table" then
			error("Expected " .. p .. " to equal " .. tostring(b) .. ", got " .. tostring(a), 0)
		end
		if getmetatable(a) ~= getmetatable(b) then
			error("Expected " .. p .. " metatables to match", 0)
		end
		for k, v in pairs(b) do deepEqualInner(a[k], v, p .. "." .. tostring(k)) end
		for k in pairs(a) do
			if b[k] == nil then error("Unexpected key " .. p .. "." .. tostring(k), 0) end
		end
	end

	local function matchInner(actual, expected, p)
		for k, v in pairs(expected) do
			local ap = p .. "." .. tostring(k)
			if type(v) == "table" and type(actual[k]) == "table" then
				matchInner(actual[k], v, ap)
			elseif actual[k] ~= v then
				error("Expected " .. ap .. " = " .. tostring(v) .. ", got " .. tostring(actual[k]), 0)
			end
		end
	end

	local testApi = {
		it = function(name, fn)
			registered[#registered + 1] = { name = name, fn = fn, skipped = false }
		end,
		skip = function(name, _fn)
			registered[#registered + 1] = { name = name, fn = nil, skipped = true }
		end,
		skipIf = function(condition)
			return function(name, fn)
				registered[#registered + 1] = {
					name    = name,
					fn      = not condition and fn or nil,
					skipped = condition == true,
				}
			end
		end,
		afterEach = function(fn) afterEachFns[#afterEachFns + 1] = fn end,
		afterAll  = function(fn) afterAllFns[#afterAllFns + 1]  = fn end,

		-- Assertion helpers — executed on the host when called from guest fn
		equal        = function(a, b) if a ~= b then error("Expected " .. tostring(a) .. " to equal " .. tostring(b), 2) end end,
		notEqual     = function(a, b) if a == b then error("Expected " .. tostring(a) .. " not to equal " .. tostring(b), 2) end end,
		truthy       = function(v)    if not v   then error("Expected truthy, got " .. tostring(v), 2) end end,
		falsy        = function(v)    if v        then error("Expected falsy, got " .. tostring(v), 2) end end,
		includes     = function(h, n) if not string.find(h, n, 1, true) then error("Expected string to include '" .. n .. "'", 2) end end,
		greater      = function(a, b) if not (a > b)  then error("Expected " .. a .. " > " .. b, 2)  end end,
		less         = function(a, b) if not (a < b)  then error("Expected " .. a .. " < " .. b, 2)  end end,
		greaterEqual = function(a, b) if not (a >= b) then error("Expected " .. a .. " >= " .. b, 2) end end,
		lessEqual    = function(a, b) if not (a <= b) then error("Expected " .. a .. " <= " .. b, 2) end end,
		count        = function(tbl)  local n = 0; for _ in pairs(tbl) do n = n + 1 end; return n end,
		deepEqual    = function(a, b) local ok, err = pcall(deepEqualInner, a, b, "<root>"); if not ok then error(err, 2) end end,
		match        = function(actual, expected)
			if type(actual) ~= "table" then error("Expected a table, got " .. type(actual), 2) end
			local ok, err = pcall(matchInner, actual, expected, "<root>")
			if not ok then error(err, 2) end
		end,
	}

	return testApi, registered, afterEachFns, afterAllFns
end

--- Run all tests collected in `registered`, reporting incrementally.
---@param registered  table
---@param afterEachFns table
---@param afterAllFns  table
---@param reporter     lde.TestReporter?
---@return lde.test.Result[]
local function runRegistered(registered, afterEachFns, afterAllFns, reporter)
	local results = {}

	for _, entry in ipairs(registered) do
		if entry.skipped then
			if reporter and reporter.onSkip then reporter.onSkip(entry.name) end
			results[#results + 1] = { name = entry.name, ok = true, skipped = true }
		else
			local handle  = reporter and reporter.onStart and reporter.onStart(entry.name)
			local ok, err = pcall(entry.fn)

			for _, fn in ipairs(afterEachFns) do
				local aok, aerr = pcall(fn)
				if not aok then ok, err = false, aerr end
			end

			if ok then
				if reporter and reporter.onPass then reporter.onPass(entry.name, handle) end
			else
				if reporter and reporter.onFail then reporter.onFail(entry.name, err, handle) end
			end
			results[#results + 1] = { name = entry.name, ok = ok, error = err }
		end
	end

	for i, fn in ipairs(afterAllFns) do
		local ok, err = pcall(fn)
		if not ok then
			results[#results + 1] = { name = "afterAll #" .. i, ok = false, error = err }
		end
	end

	return results
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

		-- Fresh test API per file; registrations are captured in host closures
		local testApi, registered, afterEachFns, afterAllFns = makeTestApi()

		-- Run the guest script; it calls test.it(...) which populates `registered`
		local ok, err = runtime.executeFile(testFile, {
			packagePath  = luaPath,
			packageCPath = luaCPath,
			preload      = {
				["lpm-test"] = function() return testApi end,
				["lde-test"] = function() return testApi end,
			},
		})

		local fileResult
		if not ok then
			fileResult = { file = relativePath, results = {}, error = err }
		else
			-- Execute the collected test fns on the host, incrementally
			local results = runRegistered(registered, afterEachFns, afterAllFns, reporter)

			local failCount = 0
			local skipCount = 0
			for _, r in ipairs(results) do
				if r.skipped then skipCount = skipCount + 1
				elseif not r.ok then failCount = failCount + 1
				end
			end

			totalTests    = totalTests    + #results - skipCount
			totalFailures = totalFailures + failCount
			totalSkipped  = totalSkipped  + skipCount

			fileResult = { file = relativePath, results = results }
		end

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
