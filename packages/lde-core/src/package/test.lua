const fs             = require("fs")
const path           = require("path")
local env            = require("env")
const ffi            = require("ffi")
const json           = require("json")
const util           = require("util")
local lua            = require("lua-sys")
const process        = require("process")
local ansi           = require("ansi")
const ldetest        = require("lde-test.test")
const coverageModule = require("lde-core.coverage")
const teal           = require("lde-core.teal")
const moonscript     = require("lde-core.moonscript")
local lde            = require("lde-core")

-- Poll interval for the sharded scheduler (the children do the waiting).
local sleep
if jit.os == "Windows" then
	pcall(ffi.cdef, "void Sleep(unsigned long dwMilliseconds);")
	sleep = function(ms) ffi.C.Sleep(ms) end
else
	pcall(ffi.cdef, "int usleep(unsigned int usec);")
	sleep = function(ms) ffi.C.usleep(ms * 1000) end
end

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

--- Silences flush-left install/build progress so it doesn't interleave with indented test results; flags always restored, skipped in verbose mode.
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
local function getLuaPathsForPackage(pkg)
	local modulesDir = pkg:getModulesDir()
	local luaPath =
		path.join(modulesDir, "?.lua") .. ";"
		.. path.join(modulesDir, "?", "init.lua") .. ";"
	const luaCPath =
		ffi.os == "Linux" ? path.join(modulesDir, "?.so") .. ";" :
		ffi.os == "Windows" ? path.join(modulesDir, "?.dll") .. ";" :
		path.join(modulesDir, "?.so") .. ";" .. path.join(modulesDir, "?.dylib") .. ";"
	return luaPath, luaCPath
end

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
	const g     = state:globals() --[[@as { package: { path: string?, cpath: string? } }]]
	const pkg   = g.package
	pkg.path    = luaPath
	pkg.cpath   = luaCPath

	-- Hook fires on all guest code; the collector filters to the package's files. Installing it disables the guest JIT, as expected.
	if coverage then
		state:setHook(function(event, info) coverage:hook(event, info) end, "line")
	end

	const runSuite = ldetest.setup(state, reporter, {
		file = testFile,
		onResult = function(name, ok, skipped, err)
			-- Spelled as the `lde.test.Result` member holds it: the alias tells the three apart by `ok`/`skipped`.
			if skipped then
				results[#results + 1] = { name = name, ok = true,      skipped = true }
			elseif ok == true then
				results[#results + 1] = { name = name, ok = true,       error = err }
			else
				results[#results + 1] = { name = name, ok = false,      error = err }
			end
		end,
	})

	-- Chunk name is the real path so debug.getinfo(1,"S").source in the guest is correct: packages like git2-sys locate native libs relative to their source file.
	local ok, err = pcall(state.eval, state, source, "@" .. testFile)
	if ok then
		-- Silences install/build progress for test bodies that install deps themselves (e.g. luarocks integration tests); guest module copies, so host reporter/verbose output is untouched.
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
	-- A file registering no tests means the suite silently does nothing; treat it as a failure.
	if #results == 0 then
		return { file = testFile, results = {}, error = "No tests were registered" }
	end
	return { file = testFile, results = results }
end

--- Builds a shell-out `lua` at ~/.lde/lua (runs lde as plain Lua, honoring LUA_PATH/LUA_CPATH) plus include//lib/ from LuaJIT for C rocks; LuaRocks drives it via -Xhelper.
local function ensureMockLuaDir()
	local lde = require("lde-core")
	local luaDir = path.join(lde.global.getDir(), "lua")
	if not fs.isdir(luaDir) then fs.mkdir(luaDir) end

	local luaBin = assert(env.execPath(), "no executable path")
	fs.delete(path.join(luaDir, "run-e.lua"))
	const wrapper = "#!/bin/sh\n"
		.. "exec '" .. luaBin .. "' --lua \"$@\"\n"
	local wrapperPath = path.join(luaDir, "lua")
	fs.write(wrapperPath, wrapper)
	fs.chmod(wrapperPath, tonumber("755", 8))

	local jitTree = require("sea").getLuajitPath()
	for _, sub in ipairs({ "include", "lib" }) do
		const link = path.join(luaDir, sub)
		if fs.exists(link) and not fs.islink(link) then
			fs.delete(link)
		end
		if not fs.exists(link) then
			fs.mklink(path.join(jitTree, sub), link)
		end
	end

	return luaDir, wrapperPath
end

--- rockspec packages: tests come from the rockspec's `test`/`test_dependencies`, run by busted from the package root; lde's binary doubles as `$(LUA)`.
---@param package  lde.Package
---@param filters  string[]? # extra args passed through to the test runner
---@param coverage boolean? # --coverage: run busted under luacov, which prints its own report
---@return lde.TestResults
local function runRockspecTests(package, filters, coverage)
	const spec = package.rockspecData
	const testSpec = spec?.test
	const testType = testSpec?.type ?? "busted"

	if not spec or testType ~= "busted" then
		return {
			package = package, files = {}, total = 0, failures = 0, skipped = 0,
			error = "Unsupported rockspec test type: " .. tostring(testType) .. " (only 'busted' is supported)",
		}
	end

	local testDeps = { busted = { luarocks = "busted" } }
	if coverage then
		testDeps.luacov = { luarocks = "luacov" }
	end
	lde.util.addRockspecDeps(testDeps, spec.test_dependencies or {})
	local luaDir, luaBin
	quiet(function()
		package:installDependencies(testDeps, package.dir)
		luaDir, luaBin = ensureMockLuaDir()
	end)

	const platform = ffi.os == "Windows" and "windows" or "unix"
	local rawFlags
	if testSpec then
		const platSpec = testSpec.platforms?.[platform]
		if platSpec and platSpec.flags then
			rawFlags = platSpec.flags
		elseif testSpec.flags then
			rawFlags = testSpec.flags
		end
	end

	local modulesDir = package:getModulesDir()
	local bustedBin = path.join(modulesDir, "busted", "busted")
	if not fs.exists(bustedBin) then
		return {
			package = package, files = {}, total = 0, failures = 0, skipped = 0,
			error = "busted was installed but its runner was not found at " .. bustedBin,
		}
	end

	-- busted's traceback walk skips frames in its own module dir and crashes when the entry is target/busted/busted, so run a copy from outside that dir.
	local cliEntry = bustedBin
	const cliSource = fs.read(bustedBin)
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

	-- cwd=package root so busted reads `.busted`; `;;` keeps default paths so spec/ and src/ stay reachable (e.g. spec.util.*).
	local luaPath = path.join(modulesDir, "?.lua") .. ";" .. path.join(modulesDir, "?", "init.lua") .. ";;"
	const soExt = ffi.os == "Windows" and "?.dll" or "?.so"
	local luaCPath = path.join(modulesDir, soExt) .. ";;"

	local exitCode = process.exec(luaBin, runArgs, {
		cwd = package.dir,
		env = { LUA_PATH = luaPath, LUA_CPATH = luaCPath },
		stdout = "inherit",
		stderr = "inherit",
	})

	-- luacov only collects stats (runreport defaults to false), so run its CLI afterwards to turn luacov.stats.out into the report.
	if coverage then
		const luacovCli = path.join(modulesDir, "luacov", "luacov")
		if fs.exists(luacovCli) then
			process.exec(luaBin, { luacovCli }, {
				cwd = package.dir,
				env = { LUA_PATH = luaPath, LUA_CPATH = luaCPath },
				stdout = "inherit",
				stderr = "inherit",
			})
			const reportPath = path.join(package.dir, "luacov.report.out")
			local report = fs.read(reportPath)
			if report then
				const summaryAt = report:find("\nSummary", 1, true)
				if summaryAt then
					print()
					print("Coverage report: " .. reportPath)
					print(report:sub(summaryAt + 1))
				end
			end
		end
	end

	-- Counts are derived from busted's exit code; external marks results from an external runner.
	const failed = exitCode ~= 0
	return {
		package  = package,
		files    = {},
		total    = failed ? 1 : 0,
		failures = failed ? 1 : 0,
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

--- Records size/mtime/hash of every file under tests/ so the copy refreshes only on real change, mirroring build.lua's build-input stamping.
const TEST_STAMP_FILE = ".lde-tests-stamp"
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

---@param testDir string
---@param stored table<string, lde.TestsStampFile>
---@return boolean hasChanged
---@return table<string, lde.TestsStampFile> current
local function checkTestsInputs(testDir, stored)
	local current = {}
	local hasChanged = false
	for _, rel in ipairs(fs.scan(testDir, "**")) do
		const relKey = rel:gsub("\\", "/")
		const abs = path.join(testDir, rel)
		const stat = fs.stat(abs)
		if not stat then
			hasChanged = true
			goto continue
		end
		local size, mtime = tonumber(stat.size) or 0, tonumber(stat.modifyTime) or 0
		const prev = stored[relKey]
		if prev and prev.size == size and prev.mtime == mtime then
			current[relKey] = prev
		else
			local content = fs.read(abs)
			local hash = content and util.hash(content) or ""
			hasChanged = hasChanged or not prev or prev.hash ~= hash
			current[relKey] = { size = size, mtime = mtime, hash = hash }
		end
		::continue::
	end
	for relKey in pairs(stored) do
		if not current[relKey] then hasChanged = true end
	end
	return hasChanged, current
end

--- Runs every test file in its own `lde test --shard-file` process so a suite's
--- slow files (network installs, native compiles, watcher timeouts) overlap.
--- Each child prints nothing and writes its result records as JSON; this process
--- renders them through the same reporter a sequential run uses, so the output is
--- identical and stays in file order.
---@param testFiles string[]
---@param package lde.Package
---@param jobs integer
---@param reporter lde.TestReporter?
---@return lde.TestResults
local function runSharded(testFiles, package, jobs, reporter)
	const execPath = assert(env.execPath(), "no executable path")
	const scratch = path.join(env.tmpdir(), "lde-shards-" .. tostring({}):match("0x(%x+)$"))
	fs.mkdirAll(scratch)

	---@param relPath string
	---@param index integer
	---@return process.Child?, string # child (nil when it could not start), result file
	local function start(relPath, index)
		const resultFile = path.join(scratch, index .. ".json")
		local args = { "test", "--shard-file", relPath, "--shard-results", resultFile }
		-- A --tree run must keep every shard on the same tree.
		if lde.global.getDir() ~= lde.global.getUserDir() then
			args[#args + 1] = "--tree"
			args[#args + 1] = lde.global.getDir()
		end
		local child, err = process.spawn(execPath, args, { stdout = "pipe", stderr = "pipe" })
		if not child then
			fs.write(resultFile, json.encode({
				files = {},
				error = "failed to start test shard for " .. relPath .. ": " .. (err or "spawn failed"),
			}))
		end
		return child, resultFile
	end

	---@type { rel: string, child: process.Child?, resultFile: string }[]
	const running = {}
	---@type table<string, { results: lde.test.Result[]?, error: string? }>
	const shards = {}
	local next = 1

	local function startNext()
		if next > #testFiles then return end
		local child, resultFile = start(testFiles[next], next)
		running[#running + 1] = { rel = testFiles[next], child = child, resultFile = resultFile }
		next += 1
	end

	local function reapFinished()
		for i = #running, 1, -1 do
			const entry = running[i]
			if not entry.child or entry.child:poll() ~= nil then
				local output = ""
				if entry.child then
					local _, stdout, stderr = entry.child:wait()
					output = (stdout or "") .. (stderr or "")
				end

				local decoded
				if fs.exists(entry.resultFile) then
					const okDecode, parsed = pcall(json.decode, fs.read(entry.resultFile) or "")
					if okDecode and type(parsed) == "table" then decoded = parsed end
				end
				if decoded then
					shards[entry.rel] = {
						results = decoded.files?.[1]?.results,
						error = decoded.files?.[1]?.error ?? decoded.error,
					}
				else
					shards[entry.rel] = {
						error = "test shard failed" .. (output ~= "" and (": " .. output) or ""),
					}
				end
				table.remove(running, i)
			end
		end
	end

	while next <= #testFiles and #running < jobs do startNext() end
	while #running > 0 do
		reapFinished()
		while next <= #testFiles and #running < jobs do startNext() end
		if #running > 0 then sleep(2) end
	end

	fs.rmdir(scratch)

	local files         = {}
	local totalTests    = 0
	local totalFailures = 0
	local totalSkipped  = 0

	for _, relativePath in ipairs(testFiles) do
		if reporter and reporter.onFileStart then reporter.onFileStart(relativePath) end

		const shard = shards[relativePath] or {}
		---@type lde.TestFileResult
		const fileResult = { file = relativePath, results = shard.results or {}, error = shard.error }

		if shard.results and reporter then
			for _, record in ipairs(shard.results) do
				if record.skipped then
					if reporter.onSkip then reporter.onSkip(record.name) end
				elseif record.ok then
					if reporter.onPass then
						const handle = reporter.onStart and reporter.onStart(record.name) or nil
						reporter.onPass(record.name, handle)
					end
				elseif reporter.onFail then
					const handle = reporter.onStart and reporter.onStart(record.name) or nil
					reporter.onFail(record.name, record.error, handle, relativePath)
				end
			end
		end

		local failCount = 0
		local skipCount = 0
		for _, r in ipairs(fileResult.results) do
			if r.skipped then skipCount += 1
			elseif not r.ok then failCount += 1
			end
		end
		if fileResult.error then failCount += 1 end

		totalTests    = totalTests    + #fileResult.results - skipCount + (fileResult.error and 1 or 0)
		totalFailures += failCount
		totalSkipped  += skipCount
		files[#files + 1] = fileResult

		if reporter and reporter.onFileDone then reporter.onFileDone(relativePath) end
	end

	return {
		package  = package,
		files    = files,
		total    = totalTests,
		failures = totalFailures,
		skipped  = totalSkipped,
	}
end

---@param package  lde.Package
---@param reporter lde.TestReporter?
---@param filters  string[]?
---@param opts     { coverage: boolean?, jobs: integer?, isShard: boolean? }?
---@return lde.TestResults
local function runTests(package, reporter, filters, opts)
	opts = opts or {}
	-- A shard child runs one file of an already-installed package: installing
	-- again (and rewriting the lockfile concurrently, once per shard) is redundant.
	if not opts.isShard then
		-- Silence install/build progress so its flush-left bars/downloads don't interleave with indented test results.
		quiet(function()
			package:installDependencies()
			package:installDevDependencies()
			package:build()
		end)
	end

	if package.isRockspec then
		return runRockspecTests(package, filters, opts.coverage)
	end

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

	-- Expose tests/ at target/tests: symlink for pure-Lua, copy for build-script packages (a symlink could be wiped by build output), stamped so edits are never served stale but unchanged runs don't re-copy.
	local targetTestsDir = path.join(package:getModulesDir(), "tests")
	local testsDir = testDir -- where the runner scans and executes from
	-- Teal takes precedence over Moonscript, matching build's src/ handling.
	const compiler = teal:hasSource(testDir) and teal
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
		-- A real dir left from a source-language run: replace with a symlink so pure-Lua tests run from source.
		fs.rmdir(targetTestsDir)
		fs.mklink(testDir, targetTestsDir)
	end

	local testFiles = fs.scan(testsDir, "**" .. path.separator .. "*.test.lua")

	if filters and #filters > 0 then
		-- Fresh list: monorepo `lde test` shares one filters table across packages, each resolving it against its own tests/ dir.
		const globs = {}
		-- Map any .tl/.moon filter onto the compiled .lua name: test files execute as compiled Lua.
		for _, filter in ipairs(filters) do
			globs[#globs + 1] = filter:gsub("%.tl$", ".lua"):gsub("%.moon$", ".lua")
		end

		for i, filter in ipairs(globs) do
			const first = filter:sub(1, 1)
			-- Project-relative when explicitly rooted ("./", "/", "C:\") or pointing at a real file; else it stays a glob under tests/.
			const resolved = path.resolve(env.cwd(), filter)
			if first == "." or first == "/" or (ffi.os == "Windows" and filter:match("^%a:\\")) or fs.exists(resolved) then
				const rel = path.relative(testDir, resolved)
				if rel and not rel:match("^%.%.") then
					globs[i] = rel == "." and "*" or rel
				end
			end
		end
		const filtered = {}
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

	if opts.jobs and opts.jobs > 1 and #testFiles > 1 and not coverage and not lde.isVerbose then
		return runSharded(testFiles, package, opts.jobs, reporter)
	end

	local files         = {}
	local totalTests    = 0
	local totalFailures = 0
	local totalSkipped  = 0

	for _, relativePath in ipairs(testFiles) do
		local testFile = path.join(testsDir, relativePath)

		if reporter and reporter.onFileStart then reporter.onFileStart(relativePath) end

		const fileResult = runTestFile(testFile, luaPath, luaCPath, reporter, coverage)
		fileResult.file  = relativePath

		local failCount = 0
		local skipCount = 0
		for _, r in ipairs(fileResult.results) do
			if r.skipped then skipCount += 1
			elseif not r.ok then failCount += 1
			end
		end

		const fileFailed = fileResult.error ? true : false
		if fileFailed then failCount += 1 end

		totalTests    = totalTests    + #fileResult.results - skipCount + (fileFailed and 1 or 0)
		totalFailures += failCount
		totalSkipped += skipCount

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
