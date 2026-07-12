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

-- ─── lde-test guest setup ─────────────────────────────────────────────────
--
-- Inject lde-test into a guest state by loading the pure-Lua framework source
-- directly via state:load(). No file I/O, no path resolution — works in
-- development, compiled binaries, and any install context.
--
-- After this call:
--   • require("lde-test") / require("lpm-test") returns an M.new() instance
--   • _lde_test_run(on_result, on_start, on_pass, on_fail, on_skip) is a
--     global callable the host invokes after the test file has executed
--
---@param state lua.State
local function setupTestFramework(state)
	-- lde-test.test source embedded as a string constant. This is the canonical
	-- copy; update it when lde-test/src/test.lua changes.
	-- It's pure Lua with zero dependencies — safe to load into any guest state.
	local LDE_TEST_SOURCE = [==[
local M = {}
local function equal(a,b) if a~=b then error("Expected "..tostring(a).." to equal "..tostring(b),2) end end
local function notEqual(a,b) if a==b then error("Expected "..tostring(a).." not to equal "..tostring(b),2) end end
local function truthy(v) if not v then error("Expected value to be truthy, got "..tostring(v),2) end end
local function falsy(v) if v then error("Expected value to be falsy, got "..tostring(v),2) end end
local function includes(h,n) if not string.find(h,n,1,true) then error("Expected string to include '"..n.."'",2) end end
local function greater(a,b) if not(a>b) then error("Expected "..tostring(a).." to be greater than "..tostring(b),2) end end
local function less(a,b) if not(a<b) then error("Expected "..tostring(a).." to be less than "..tostring(b),2) end end
local function greaterEqual(a,b) if not(a>=b) then error("Expected "..tostring(a).." to be greater than or equal to "..tostring(b),2) end end
local function lessEqual(a,b) if not(a<=b) then error("Expected "..tostring(a).." to be less than or equal to "..tostring(b),2) end end
local function count(t) local n=0; for _ in pairs(t) do n=n+1 end; return n end
local function deepEqualInner(a,b,p)
	if a==b then return end
	if type(a)~=type(b) then error("Expected "..p.." to be "..type(b)..", got "..type(a),0) end
	if type(a)~="table" then error("Expected "..p.." to equal "..tostring(b)..", got "..tostring(a),0) end
	if getmetatable(a)~=getmetatable(b) then error("Expected "..p.." metatables to match",0) end
	for k,v in pairs(b) do deepEqualInner(a[k],v,p.."."..tostring(k)) end
	for k in pairs(a) do if b[k]==nil then error("Unexpected key "..p.."."..tostring(k),0) end end
end
local function deepEqual(a,b) local ok,err=pcall(deepEqualInner,a,b,"<root>"); if not ok then error(err,2) end end
local function matchInner(actual,expected,p)
	for k,v in pairs(expected) do
		local ap=p.."."..tostring(k)
		if type(v)=="table" and type(actual[k])=="table" then matchInner(actual[k],v,ap)
		elseif actual[k]~=v then error("Expected "..ap.." to equal "..tostring(v)..", got "..tostring(actual[k]),0) end
	end
end
local function match(actual,expected)
	if type(actual)~="table" then error("Expected a table, got "..type(actual),2) end
	local ok,err=pcall(matchInner,actual,expected,"<root>"); if not ok then error(err,2) end
end
function M.new()
	local callbacks,afterEachFns,afterAllFns={},{},{}
	local instance={}
	function instance.it(name,fn) table.insert(callbacks,{name=name,callback=fn}) end
	function instance.skip(name,_fn) table.insert(callbacks,{name=name,skipped=true}) end
	function instance.skipIf(condition)
		return function(name,fn)
			table.insert(callbacks,condition and {name=name,skipped=true} or {name=name,callback=fn})
		end
	end
	function instance.afterEach(fn) table.insert(afterEachFns,fn) end
	function instance.afterAll(fn) table.insert(afterAllFns,fn) end
	function instance.run(reporter)
		local results={}; reporter=reporter or {}
		for _,cb in ipairs(callbacks) do
			if cb.skipped then
				if reporter.onSkip then reporter.onSkip(cb.name) end
				table.insert(results,{name=cb.name,ok=true,skipped=true})
			else
				local handle=reporter.onStart and reporter.onStart(cb.name)
				local ok,err=pcall(cb.callback)
				for _,fn in ipairs(afterEachFns) do local aok,aerr=pcall(fn); if not aok then ok,err=false,aerr end end
				if ok and reporter.onPass then reporter.onPass(cb.name,handle)
				elseif not ok and reporter.onFail then reporter.onFail(cb.name,err,handle) end
				table.insert(results,{name=cb.name,ok=ok,error=err})
			end
		end
		for i,fn in ipairs(afterAllFns) do
			local ok,err=pcall(fn); if not ok then table.insert(results,{name="afterAll #"..i,ok=false,error=err}) end
		end
		return results
	end
	instance.equal=equal; instance.notEqual=notEqual; instance.truthy=truthy; instance.falsy=falsy
	instance.includes=includes; instance.greater=greater; instance.less=less
	instance.greaterEqual=greaterEqual; instance.lessEqual=lessEqual
	instance.count=count; instance.deepEqual=deepEqual; instance.match=match
	return instance
end
return M
]==]

	state:eval(string.format([[
		local _factory = assert(load(%q, "@lde-test.test"))()
		local _instance = _factory.new()
		package.preload["lde-test"] = function() return _instance end
		package.preload["lpm-test"] = function() return _instance end
		_lde_test_run = function()
			local reporter = {}
			if _lde_on_start then reporter.onStart = function(name)         _lde_on_start(name)        end end
			if _lde_on_pass  then reporter.onPass  = function(name, _)      _lde_on_pass(name)         end end
			if _lde_on_fail  then reporter.onFail  = function(name, err, _) _lde_on_fail(name, err)    end end
			if _lde_on_skip  then reporter.onSkip  = function(name)         _lde_on_skip(name)         end end
			for _, r in ipairs(_instance.run(reporter)) do
				_lde_on_result(r.name, r.ok == true, r.skipped == true, r.error or "")
			end
		end
	]], LDE_TEST_SOURCE))
end

--- Run a single test file in a fresh guest state.
---@param testFile   string
---@param luaPath    string
---@param luaCPath   string
---@param reporter   lde.TestReporter?
---@return lde.TestFileResult
local function runTestFile(testFile, luaPath, luaCPath, reporter)
	local results = {}
	local handles = {}

	local onResult = function(name, ok, skipped, err)
		if skipped then
			results[#results + 1] = { name = name, ok = true,      skipped = true }
		else
			results[#results + 1] = { name = name, ok = ok == true, error  = err   }
		end
	end
	-- Handles are kept entirely on the host side — the bridge cannot return
	-- compound values (tables) from host callbacks back into the guest.
	-- onStart fires from the host wrapper; its handle is stored in `handles`
	-- here and retrieved when onPass/onFail fire (also host-side wrappers).
	-- Only primitives (name string, ok boolean, err string) cross the boundary.
	local onStart = reporter and reporter.onStart and function(name)
		handles[name] = reporter.onStart(name)
		-- return nothing — no compound value crosses to guest
	end or nil
	local onPass = reporter and reporter.onPass and function(name)
		reporter.onPass(name, handles[name]); handles[name] = nil
	end or nil
	local onFail = reporter and reporter.onFail and function(name, err)
		reporter.onFail(name, err, handles[name]); handles[name] = nil
	end or nil
	local onSkip = reporter and reporter.onSkip and function(name)
		reporter.onSkip(name)
	end or nil

	local source, readErr = fs.read(testFile)
	if not source then
		return { file = testFile, results = {}, error = "Could not read: " .. (readErr or "?") }
	end

	-- Build the guest state manually so we can call setupTestFramework before
	-- loading the test file source.
	local state = lua.new()
	local g     = state:globals()
	local pkg   = g.package
	pkg.path    = luaPath
	pkg.cpath   = luaCPath

	-- Inject lde-test framework entirely within the guest
	setupTestFramework(state)

	-- Inject reporter callbacks as guest globals (primitives only cross boundary)
	g._lde_on_result = onResult
	if onStart then g._lde_on_start = onStart end
	if onPass  then g._lde_on_pass  = onPass  end
	if onFail  then g._lde_on_fail  = onFail  end
	if onSkip  then g._lde_on_skip  = onSkip  end

	-- Run the test file source with the real file path as chunk name so that
	-- debug.getinfo(1,"S").source inside the guest returns the correct path.
	-- This is required by packages like git2-sys that locate native libraries
	-- relative to their own source file at load time.
	local ok, err = pcall(state.eval, state, source, "@" .. testFile)
	if ok then
		local runFn = g._lde_test_run
		ok, err = pcall(runFn)
	end

	state:close()

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
