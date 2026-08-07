local fs      = require("fs")
local path    = require("path")
local env     = require("env")
local ffi     = require("ffi")
local lua     = require("lua-sys")
local process = require("process")
local rocked  = require("rocked")
local ldetest = require("lde-test.test")

---@class lde.TestFileResult
---@field file    string
---@field results lde.test.Result[]
---@field error   string?

---@class lde.TestResults
---@field package  lde.Package
---@field files    lde.TestFileResult[]
---@field total    number
---@field failures number
---@field skipped  number
---@field error    string?
---@field external boolean? # true when tests ran under an external runner (busted)
---@field exitCode number? # exit code of the external runner

local function getLuaPathsForPackage(pkg)
	local modulesDir = pkg:getModulesDir()
	local luaPath =
		path.join(modulesDir, "?.lua") .. ";"
		.. path.join(modulesDir, "?", "init.lua") .. ";"
	local luaCPath =
		ffi.os == "Linux"    and path.join(modulesDir, "?.so")    .. ";"
		or ffi.os == "Windows" and path.join(modulesDir, "?.dll")  .. ";"
		or path.join(modulesDir, "?.so") .. ";" .. path.join(modulesDir, "?.dylib") .. ";"
	return luaPath, luaCPath
end

-- ─── lde-test guest setup ─────────────────────────────────────────────────
--
-- The framework is injected by lde-test.test: it loads the framework source
-- into the guest state and returns the suite runner. The runner is invoked
-- after the test file source has been evaluated; results stream back through
-- the host callback wired in runTestFile below. No globals cross the
-- boundary — the reporter callbacks are passed as varargs on injection.

--- Run a single test file in a fresh guest state.
---@param testFile   string
---@param luaPath    string
---@param luaCPath   string
---@param reporter   lde.TestReporter?
---@return lde.TestFileResult
local function runTestFile(testFile, luaPath, luaCPath, reporter)
	local source, readErr = fs.read(testFile)
	if not source then
		return { file = testFile, results = {}, error = "Could not read: " .. (readErr or "?") }
	end

	local results = {}

	local state = lua.new()
	local g     = state:globals()
	local pkg   = g.package
	pkg.path    = luaPath
	pkg.cpath   = luaCPath

	-- Inject lde-test into the guest (framework source + reporter wiring) and
	-- grab the suite runner to invoke once the test file has been evaluated.
	local runSuite = ldetest.setup(state, reporter, {
		file = testFile,
		onResult = function(name, ok, skipped, err)
			if skipped then
				results[#results + 1] = { name = name, ok = true,      skipped = true }
			else
				results[#results + 1] = { name = name, ok = ok == true, error  = err   }
			end
		end,
	})

	-- Run the test file source with the real file path as chunk name so that
	-- debug.getinfo(1,"S").source inside the guest returns the correct path.
	-- This is required by packages like git2-sys that locate native libraries
	-- relative to their own source file at load time.
	local ok, err = pcall(state.eval, state, source, "@" .. testFile)
	if ok then
		ok, err = pcall(runSuite)
	end

	state:close()

	if not ok then
		return { file = testFile, results = {}, error = err }
	end
	-- A file that ran cleanly but registered no tests (no it/skip calls)
	-- means the suite silently does nothing — treat it as a failure.
	if #results == 0 then
		return { file = testFile, results = {}, error = "No tests were registered" }
	end
	return { file = testFile, results = results }
end

--- Create a minimal Lua installation at ~/.lde/lua that test harnesses can
--- shell out to: a `lua` executable that runs the lde binary as a plain Lua
--- interpreter (so scripts run with the harness's LUA_PATH/LUA_CPATH env
--- instead of any package context), plus include/ and lib/ symlinked to the
--- LuaJIT dev tree so C rocks the harness builds (e.g. cluacov) find headers
--- and libs. LuaRocks' own test suite drives this via the rockspec test flags
--- `-Xhelper lua=$(LUA) -Xhelper lua_dir=$(LUA_DIR)`.
---@return string luaDir
---@return string luaBin
local function ensureMockLuaDir()
	local lde = require("lde-core")
	local luaDir = path.join(lde.global.getDir(), "lua")
	if not fs.isdir(luaDir) then fs.mkdir(luaDir) end

	local luaBin = assert(env.execPath(), "no executable path")
	-- The wrapper hands the whole command line to `lde --lua`, which
	-- interprets it like a `lua` invocation (`-e <code>` chunks, optional
	-- script, `-i` REPL) in a plain state honoring LUA_PATH/LUA_CPATH env.
	-- Remove the pre-0.11 driver file this replaced, if present.
	fs.delete(path.join(luaDir, "run-e.lua"))
	local wrapper = "#!/bin/sh\n"
		.. "exec '" .. luaBin .. "' --lua \"$@\"\n"
	local wrapperPath = path.join(luaDir, "lua")
	fs.write(wrapperPath, wrapper)
	fs.chmod(wrapperPath, tonumber("755", 8))

	-- Headers/libs for native rocks the harness compiles.
	local jitTree = require("sea").getLuajitPath()
	for _, sub in ipairs({ "include", "lib" }) do
		local link = path.join(luaDir, sub)
		if fs.exists(link) and not fs.islink(link) then
			fs.delete(link)
		end
		if not fs.exists(link) then
			fs.mklink(path.join(jitTree, sub), link)
		end
	end

	return luaDir, wrapperPath
end

--- Run the test specification of a rockspec-based package.
---
--- LuaRocks packages don't use the tests/*.test.lua layout; their tests are
--- defined by the rockspec itself: a `test` section (a framework plus
--- per-platform flags) and `test_dependencies` (rocks installed only for
--- testing). busted is the supported framework: lde installs it (plus the
--- declared test rocks) into target/ and invokes it from the package root,
--- where busted picks up the `.busted` config, `spec/` directory, and helper
--- scripts automatically. lde's own binary doubles as the Lua interpreter, so
--- test harnesses that shell out to `$(LUA)` (e.g. the LuaRocks test suite
--- running its in-tree `src/bin/luarocks`) work without a system Lua install.
---@param package  lde.Package
---@param filters  string[]? # extra args passed through to the test runner
---@return lde.TestResults
local function runRockspecTests(package, filters)
	local spec = package.rockspecData
	local testSpec = spec and spec.test
	local testType = testSpec and testSpec.type or "busted"

	if not spec or testType ~= "busted" then
		return {
			package = package, files = {}, total = 0, failures = 0, skipped = 0,
			error = "Unsupported rockspec test type: " .. tostring(testType) .. " (only 'busted' is supported)",
		}
	end

	-- Test-only rocks: the busted framework itself plus whatever the rockspec
	-- declares in test_dependencies (e.g. coverage runners, output handlers).
	local testDeps = { busted = { luarocks = "busted" } }
	for _, depStr in ipairs(spec.test_dependencies or {}) do
		local name, version = rocked.parseDependency(depStr)
		if name and name ~= "lua" and name ~= "luajit" then
			testDeps[name] = { luarocks = name, version = version }
		end
	end
	package:installDependencies(testDeps, package.dir)

	-- Per-platform flags from the rockspec's test section.
	local platform = ffi.os == "Windows" and "windows" or "unix"
	local rawFlags
	if testSpec then
		local platSpec = testSpec.platforms and testSpec.platforms[platform]
		if platSpec and platSpec.flags then
			rawFlags = platSpec.flags
		elseif testSpec.flags then
			rawFlags = testSpec.flags
		end
	end

	-- The interpreter test harnesses shell out to: `$(LUA)` is a wrapper that
	-- runs the lde binary as plain Lua (so scripts see the harness's env paths,
	-- not any package context), and `$(LUA_DIR)` is the mock Lua install dir
	-- (~/.lde/lua) with headers/libs for C rocks the harness builds.
	local luaDir, luaBin = ensureMockLuaDir()

	local modulesDir = package:getModulesDir()
	local bustedBin = path.join(modulesDir, "busted", "busted")
	if not fs.exists(bustedBin) then
		return {
			package = package, files = {}, total = 0, failures = 0, skipped = 0,
			error = "busted was installed but its runner was not found at " .. bustedBin,
		}
	end

	-- TODO: replace this hacky fix
	-- busted's traceback walk (busted/core.lua getTrace) skips every frame whose
	-- source lives in busted's own module directory, then keeps walking until
	-- debug.getinfo returns nil and crashes — replacing every real error message
	-- with nil ("Nil error", 0 tests run). The CLI entry lives in target/busted/,
	-- so running it directly as the main script always hits this. Run a copy of
	-- the entry from outside that dir so the walk stops at the main chunk and
	-- error traces resolve normally.
	local cliEntry = bustedBin
	local cliSource = fs.read(bustedBin)
	if cliSource then
		cliEntry = path.join(modulesDir, "busted-cli.lua")
		if fs.read(cliEntry) ~= cliSource then
			fs.write(cliEntry, cliSource)
		end
	end

	local runArgs = { cliEntry }
	for _, flag in ipairs(rawFlags or {}) do
		runArgs[#runArgs + 1] = (flag:gsub("%$%(LUA%)", luaBin):gsub("%$%(LUA_DIR%)", luaDir))
	end
	for _, filter in ipairs(filters or {}) do
		runArgs[#runArgs + 1] = filter
	end

	-- Run busted as a subprocess with the package root as cwd: busted reads
	-- `.busted` from there, and the `;;` in LUA_PATH/LUA_CPATH keeps the default
	-- paths (incl. ./?.lua) so the package's own spec/ and src/ stay reachable
	-- (e.g. spec.util.* helpers, modules busted's --lpath prefix doesn't cover).
	local luaPath = path.join(modulesDir, "?.lua") .. ";" .. path.join(modulesDir, "?", "init.lua") .. ";;"
	local soExt = ffi.os == "Windows" and "?.dll" or "?.so"
	local luaCPath = path.join(modulesDir, soExt) .. ";;"

	local exitCode = process.exec(luaBin, runArgs, {
		cwd = package.dir,
		env = { LUA_PATH = luaPath, LUA_CPATH = luaCPath },
		stdout = "inherit",
		stderr = "inherit",
	})

	-- busted reports counts in its own output; the summary here is derived from
	-- its exit code. external marks results that came from an external runner.
	local failed = exitCode ~= 0
	return {
		package  = package,
		files    = {},
		total    = failed and 1 or 0,
		failures = failed and 1 or 0,
		skipped  = 0,
		external = true,
		exitCode = exitCode,
	}
end

---@param package  lde.Package
---@param reporter lde.TestReporter?
---@param filters  string[]?
---@return lde.TestResults
local function runTests(package, reporter, filters)
	package:installDependencies()
	package:installDevDependencies()
	package:build()

	-- Rockspec-based packages run their test specification (busted) instead of
	-- lde-test files.
	if package.isRockspec then
		return runRockspecTests(package, filters)
	end

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

		-- A file that fails to load ran no tests, but is itself a failure.
		local fileFailed = fileResult.error and true or false
		if fileFailed then failCount = failCount + 1 end

		totalTests    = totalTests    + #fileResult.results - skipCount + (fileFailed and 1 or 0)
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
