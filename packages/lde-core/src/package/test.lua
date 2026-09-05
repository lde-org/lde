local fs             = require("fs")
local path           = require("path")
local env            = require("env")
local ffi            = require("ffi")
local json           = require("json")
local util           = require("util")
local lua            = require("lua-sys")
local process        = require("process")
local rocked         = require("rocked")
local ansi           = require("ansi")
local ldetest        = require("lde-test.test")
local coverageModule = require("lde-core.coverage")
local teal           = require("lde-core.teal")
local moonscript     = require("lde-core.moonscript")
local lde            = require("lde-core")

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
---@field coverageRan boolean? # external runner was asked to collect coverage (busted --coverage)
---@field exitCode number? # exit code of the external runner
---@field coverage lde.Coverage? # line coverage collected during the run (--coverage)

--- Run fn() with install/build progress silenced: compact install bars and
--- one-off downloads (e.g. the LuaJIT tree) print flush-left, which would
--- interleave with the indented test results. The reporter's own progress
--- (created while test files run, outside fn()) is untouched. Skipped in
--- verbose mode, where streaming build output is the point. Flags are always
--- restored, even when fn() raises.
---@param fn fun()
local function quiet(fn)
	if lde.isVerbose then return fn() end
	local wasQuiet, wasAnsiQuiet = lde.isQuiet, ansi.isQuiet
	lde.isQuiet, ansi.isQuiet = true, true
	local ok, result = pcall(fn)
	ansi.isQuiet, lde.isQuiet = wasAnsiQuiet, wasQuiet
	if not ok then error(result, 0) end
	return result
end

---@param pkg lde.Package
---@return string luaPath
---@return string luaCPath
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
---@param coverage   lde.Coverage? # shared line-coverage collector, nil disables
---@return lde.TestFileResult
local function runTestFile(testFile, luaPath, luaCPath, reporter, coverage)
	local source, readErr = fs.read(testFile)
	if not source then
		return { file = testFile, results = {}, error = "Could not read: " .. (readErr or "?") }
	end

	local results = {}

	local state = lua.new()
	local g     = state:globals() --[[@as { package: { path: string?, cpath: string? } }]]
	local pkg   = g.package
	pkg.path    = luaPath
	pkg.cpath   = luaCPath

	-- Instrument every executed line of the package's own source. The hook
	-- fires on all guest code (deps, framework, stdlib too); the collector
	-- filters to the package's files. Installing it disables the guest JIT,
	-- which is expected — coverage runs are interpreted.
	if coverage then
		state:setHook(function(event, info) coverage:hook(event, info) end, "line")
	end

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
		-- Test bodies may install dependencies themselves (e.g. luarocks
		-- integration tests); silence their flush-left install/build progress
		-- the same way runTests silences the package's own install. The flags
		-- are set on the guest's module copies (fresh per state), so the
		-- host-side reporter progress — and --verbose streaming — is untouched.
		if not lde.isVerbose then
			pcall(state.eval, state,
				"local lde = package.loaded[\"lde-core\"]\n"
				.. "if lde then lde.isQuiet = true end\n"
				.. "local ansi = package.loaded[\"ansi\"]\n"
				.. "if ansi then ansi.isQuiet = true end\n",
				"@lde-test.quiet")
		end
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
---@param coverage boolean? # --coverage: run busted under luacov, which prints its own report
---@return lde.TestResults
local function runRockspecTests(package, filters, coverage)
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
	if coverage then
		-- busted --coverage runs luacov, which prints its own report.
		testDeps.luacov = { luarocks = "luacov" }
	end
	lde.util.addRockspecDeps(testDeps, spec.test_dependencies or {})
	-- Quiet: the test rocks and the mock-Lua setup (which may download the
	-- LuaJIT tree) print flush-left progress; busted runs below with output
	-- restored.
	local luaDir, luaBin
	quiet(function()
		package:installDependencies(testDeps, package.dir)
		luaDir, luaBin = ensureMockLuaDir()
	end)

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
	if coverage then
		runArgs[#runArgs + 1] = "--coverage"
	end
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

	-- busted --coverage runs luacov, which only collects stats during the run
	-- (runreport defaults to false). Run the luacov CLI afterwards to turn
	-- luacov.stats.out into a report, then print its summary table.
	if coverage then
		local luacovCli = path.join(modulesDir, "luacov", "luacov")
		if fs.exists(luacovCli) then
			process.exec(luaBin, { luacovCli }, {
				cwd = package.dir,
				env = { LUA_PATH = luaPath, LUA_CPATH = luaCPath },
				stdout = "inherit",
				stderr = "inherit",
			})
			local reportPath = path.join(package.dir, "luacov.report.out")
			local report = fs.read(reportPath)
			if report then
				local summaryAt = report:find("\nSummary", 1, true)
				if summaryAt then
					print()
					print("Coverage report: " .. reportPath)
					print(report:sub(summaryAt + 1))
				end
			end
		end
	end

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
		coverageRan = coverage,
		exitCode = exitCode,
	}
end

---@class lde.TestsStampFile
---@field size number
---@field mtime number
---@field hash string

--- Stamp file written inside the target/tests copy. Records the size, mtime,
--- and rapidhash hash of every file under tests/ so the copy is only refreshed
--- when the source actually changed — the same approach build.lua uses for
--- build inputs.
local TEST_STAMP_FILE = ".lde-tests-stamp"
local TEST_STAMP_VERSION = 1

---@param stampPath string
---@return table<string, lde.TestsStampFile>
local function readTestsStamp(stampPath)
	local content = fs.read(stampPath)
	if not content then return {} end
	local ok, decoded = pcall(json.decode, content)
	if not ok or type(decoded) ~= "table" or decoded.version ~= TEST_STAMP_VERSION or type(decoded.files) ~= "table" then
		return {}
	end
	return decoded.files
end

--- Compare tests/ against the stored stamp. Files whose size+mtime are
--- Unchanged inputs reuse the stored hash; anything else is re-hashed. Returns
--- whether the copy is stale and the current per-file state to persist.
---@param testDir string
---@param stored table<string, lde.TestsStampFile>
---@return boolean hasChanged
---@return table<string, lde.TestsStampFile> current
local function checkTestsInputs(testDir, stored)
	local current = {}
	local hasChanged = false
	for _, rel in ipairs(fs.scan(testDir, "**")) do
		local relKey = rel:gsub("\\", "/")
		local abs = path.join(testDir, rel)
		local stat = fs.stat(abs)
		if not stat then
			hasChanged = true
			goto continue
		end
		local size, mtime = tonumber(stat.size) or 0, tonumber(stat.modifyTime) or 0
		local prev = stored[relKey]
		if prev and prev.size == size and prev.mtime == mtime then
			-- Fast path: size + mtime unchanged, the stored hash is still valid.
			current[relKey] = prev
		else
			local content = fs.read(abs)
			local hash = content and util.hash(content) or ""
			hasChanged = hasChanged or not prev or prev.hash ~= hash
			current[relKey] = { size = size, mtime = mtime, hash = hash }
		end
		::continue::
	end
	-- Files that were inputs to the last copy but no longer exist.
	for relKey in pairs(stored) do
		if not current[relKey] then hasChanged = true end
	end
	return hasChanged, current
end

---@param package  lde.Package
---@param reporter lde.TestReporter?
---@param filters  string[]?
---@param opts     { coverage: boolean? }?
---@return lde.TestResults
local function runTests(package, reporter, filters, opts)
	opts = opts or {}
	-- Dependencies and the build happen before any test output: their
	-- progress (compact bars, luajit downloads) prints flush-left, so silence
	-- it here instead of interleaving it with the indented test results.
	quiet(function()
		package:installDependencies()
		package:installDevDependencies()
		package:build()
	end)

	-- Rockspec-based packages run their test specification (busted) instead of
	-- lde-test files.
	if package.isRockspec then
		return runRockspecTests(package, filters, opts.coverage)
	end

	-- In-scope files for coverage: the package's built output (target/<name>,
	-- where require resolves its own modules) and src/ (for direct loads).
	local coverage
	if opts.coverage then
		coverage = coverageModule.new({
			package:getTargetDir() .. path.separator,
			package:getSrcDir() .. path.separator,
		}, package:getDir())
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

	-- Expose tests/ via target/tests so test files can require each other.
	-- Tests written in Teal (.tl) or Moonscript (.moon) are compiled to Lua
	-- there first — mirroring how build() compiles src/ — so the runner below
	-- only ever executes Lua. Build-script packages get a copy (a symlink
	-- could be shadowed or wiped by the build output); like build inputs,
	-- it's stamped so it's refreshed only when tests/ actually changed —
	-- edits to tests/ (e.g. helpers under tests/lib) are never served stale,
	-- but unchanged runs don't re-copy.
	local targetTestsDir = path.join(package:getModulesDir(), "tests")
	local testsDir = testDir -- where the runner scans and executes from
	-- Teal takes precedence over Moonscript, matching build's src/ handling.
	local compiler = teal:hasSource(testDir) and teal
		or moonscript:hasSource(testDir) and moonscript
		or nil
	if compiler then
		if fs.islink(targetTestsDir) then
			fs.delete(targetTestsDir)
		elseif fs.exists(targetTestsDir) then
			fs.rmdir(targetTestsDir)
		end
		compiler:compileDir(testDir, targetTestsDir)
		testsDir = targetTestsDir
	elseif package:hasBuildScript() then
		local stampPath = path.join(targetTestsDir, TEST_STAMP_FILE)
		local hasChanged, current = checkTestsInputs(testDir, readTestsStamp(stampPath))
		if hasChanged or not fs.exists(targetTestsDir) then
			if fs.islink(targetTestsDir) then
				fs.delete(targetTestsDir)
			elseif fs.exists(targetTestsDir) then
				fs.rmdir(targetTestsDir)
			end
			fs.copy(testDir, targetTestsDir)
			fs.write(stampPath, json.encode({ version = TEST_STAMP_VERSION, files = current }))
		end
	elseif not fs.exists(targetTestsDir) then
		fs.mklink(testDir, targetTestsDir)
	elseif not fs.islink(targetTestsDir) then
		-- A real directory left over from a previous source-language run:
		-- replace it with a fresh symlink so pure-Lua tests run from source.
		fs.rmdir(targetTestsDir)
		fs.mklink(testDir, targetTestsDir)
	end

	local testFiles = fs.scan(testsDir, "**" .. path.separator .. "*.test.lua")

	if filters and #filters > 0 then
		-- Normalize into a fresh list — runTests must never mutate the
		-- caller's table: monorepo `lde test` runs every package with the
		-- same filters, each resolved against that package's own tests/ dir.
		local globs = {}
		-- Test files execute as compiled Lua; map any .tl/.moon filter (e.g.
		-- `lde test -- tests/foo.test.tl`) onto the compiled .lua name.
		for _, filter in ipairs(filters) do
			globs[#globs + 1] = filter:gsub("%.tl$", ".lua"):gsub("%.moon$", ".lua")
		end

		for i, filter in ipairs(globs) do
			local first = filter:sub(1, 1)
			-- A filter is treated as a project-relative path when it is
			-- explicitly rooted ("./", "/", "C:\") or when it points at a real
			-- file (e.g. `lde test -- tests/foo.test.lua`); anything else
			-- stays a glob matched against paths under tests/.
			local resolved = path.resolve(env.cwd(), filter)
			if first == "." or first == "/" or (ffi.os == "Windows" and filter:match("^%a:\\")) or fs.exists(resolved) then
				local rel = path.relative(testDir, resolved)
				if rel and not rel:match("^%.%.") then
					globs[i] = rel == "." and "*" or rel
				end
			end
		end
		local filtered = {}
		for _, relPath in ipairs(testFiles) do
			for _, glob in ipairs(globs) do
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
		local testFile = path.join(testsDir, relativePath)

		if reporter and reporter.onFileStart then reporter.onFileStart(relativePath) end

		local fileResult = runTestFile(testFile, luaPath, luaCPath, reporter, coverage)
		fileResult.file  = relativePath

		local failCount = 0
		local skipCount = 0
		for _, r in ipairs(fileResult.results) do
			if r.skipped then skipCount += 1
			elseif not r.ok then failCount += 1
			end
		end

		-- A file that fails to load ran no tests, but is itself a failure.
		local fileFailed = fileResult.error and true or false
		if fileFailed then failCount += 1 end

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
		skipped  = totalSkipped,
		coverage = coverage,
	}
end

return runTests
