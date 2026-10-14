const fs = require("fs")
const path = require("path")
const ansi = require("ansi")
const env = require("env")
const process = require("process")
const ffi = require("ffi")

const json = require("json")
const errorsnippet = require("lde.util.errorsnippet")

--- Default shard count: one per available CPU, capped so a small suite does not
--- spawn more processes than it has files.
---@return integer
local function defaultJobs()
	const _, out = process.exec("nproc")
	local text = (out or ""):gsub("%s+$", "")
	local count = tonumber(text) or 0
	if count < 1 then count = 4 end
	return math.min(count, 8)
end

const lde = require("lde-core")

local sleep
if jit.os == "Windows" then
	pcall(ffi.cdef, "void Sleep(unsigned long dwMilliseconds);")
	sleep = function(ms) ffi.C.Sleep(ms) end
else
	pcall(ffi.cdef, "int usleep(unsigned int usec);")
	sleep = function(ms) ffi.C.usleep(ms * 1000) end
end

---@param pkgDir string
---@return lde.TestReporter
local function makeReporter(pkgDir)
	local firstFile = true
	return {
		onFileStart = function(file)
			if not firstFile then
				print()
			end
			firstFile = false
			ansi.printf("  {bold}%s", file)
		end,
		onStart = function(name)
			return ansi.progress(name, { stream = "stdout" })
		end,
		onPass = function(name, handle)
			handle:done(name)
		end,
		onFail = function(name, err, handle, file)
			handle:fail(name)
			-- Errors without a file position (e.g. error("boom", 0)) fall back to a plain message.
			if not errorsnippet.printError(pkgDir, err or "unknown error", file) then
				ansi.printf("     {red}%s", err or "unknown error")
			end
		end,
		onSkip = function(name)
			ansi.printf("   {yellow}- {gray}%s {yellow}(skipped)", name)
		end,
	}
end

---@param results lde.TestResults
---@param pkgDir string
local function printFileErrors(results, pkgDir)
	for _, file in ipairs(results.files) do
		if file.error then
			ansi.printf("  {red}FAIL {white}%s", file.file)
			local testDir = results.package ? (results.package:getTestDir()) : pkgDir
			if not errorsnippet.printError(pkgDir, file.error, path.join(testDir, file.file)) then
				ansi.printf("     {red}%s", file.error)
			end
			print()
		end
	end
end

---@param failures number
---@param passed number
---@param total number
---@param skipped number
local function printSummary(failures, passed, total, skipped)
	local skipStr = skipped > 0 ? ansi.format(", {yellow}%d skipped", skipped) : ""
	if failures > 0 then
		ansi.printf("{white}Tests:  {red}%d failed{white}, {green}%d passed{white}, {cyan}%d total" .. skipStr, failures,
			passed, total)
	else
		ansi.printf("{white}Tests:  {green}%d passed{white}, {cyan}%d total" .. skipStr, passed, total)
	end
end

---@param percent number
local function percentColor(percent)
	if percent >= 90 then return "green" end
	if percent >= 70 then return "yellow" end
	return "red"
end

---@class lde.CoverageFileRow
---@field file string # display path (src/...)
---@field executable number
---@field covered number
---@field percent number

---@class lde.CoverageReport
---@field package string
---@field files lde.CoverageFileRow[] # sorted worst-first
---@field totalExecutable number
---@field totalCovered number
---@field percent number

-- Shared by the text printer and the --json emitter so both see identical data.
---@param pkg lde.Package
---@param coverage lde.Coverage
---@return lde.CoverageReport
local function coverageReport(pkg, coverage)
	local files, totalExecutable, totalCovered = coverage:compute()

	local pkgDir = pkg:getDir()
	const targetPrefix = path.join("target", pkg:getName()) .. path.separator

	---@type lde.CoverageFileRow[]
	local rows = {}
	for _, f in ipairs(files) do
		local rel = path.relative(pkgDir, f.file) or f.file
		if rel:sub(1, #targetPrefix) == targetPrefix then
			rel = path.join("src", rel:sub(#targetPrefix + 1))
		end
		-- Forward slashes on every platform: path.relative/join use the OS separator.
		rel = rel:gsub("\\", "/")
		rows[#rows + 1] = {
			file = rel,
			executable = f.executable,
			covered = f.covered,
			percent = f.executable > 0 and f.covered / f.executable * 100 or 0,
		}
	end
	table.sort(rows, function(a, b)
		if a.percent ~= b.percent then return a.percent < b.percent end
		return a.file < b.file
	end)

	return {
		package = pkg:getName(),
		files = rows,
		totalExecutable = totalExecutable,
		totalCovered = totalCovered,
		percent = totalExecutable > 0 and totalCovered / totalExecutable * 100 or 0,
	}
end

-- Files show as src/ paths (modules load from target/<name>, the built copy of src/), sorted worst-first.
---@param pkg lde.Package
---@param coverage lde.Coverage
local function printCoverage(pkg, coverage)
	const report = coverageReport(pkg, coverage)
	local rows = report.files
	if #rows == 0 then
		ansi.printf("  {yellow}Coverage: no source files were loaded")
		return
	end

	local totalExecutable, totalCovered = report.totalExecutable, report.totalCovered

	-- Files left-aligned (min 38), covered/total ratio right-aligned as a unit, so the percentage aligns on every row.
	local fileW = 38
	local covW, totW = 1, 1
	for _, r in ipairs(rows) do
		fileW = math.max(fileW, #r.file)
		covW = math.max(covW, #tostring(r.covered))
		totW = math.max(totW, #tostring(r.executable))
	end
	const ratioW = covW + 1 + totW
	-- Widest row: 2 indent + file + 1 + ratio + 1 + "lines" + 2 + "100.0%".
	const sepW = fileW + ratioW + 17

	print()
	ansi.printf("  {bold}Coverage")
	print("  " .. ansi.colorize("gray", string.rep("─", sepW)))
	for _, r in ipairs(rows) do
		-- Spliced in at runtime so ansi.format resolves it; {%s} would survive gsub and print literally.
		const color = percentColor(r.percent)
		ansi.printf("  {gray}%-" .. fileW .. "s{reset} %" .. ratioW .. "s {gray}lines{reset}  {" .. color .. "}%.1f%%",
			r.file, ("%d/%d"):format(r.covered, r.executable), r.percent)
	end
	print("  " .. ansi.colorize("gray", string.rep("─", sepW)))
	const totalPercent = totalExecutable > 0 and totalCovered / totalExecutable * 100 or 0
	const totalColor = percentColor(totalPercent)
	-- Right-align the Total's ratio with the rows ("  Total: " is 9 chars).
	ansi.printf("  Total: %s {gray}lines{reset}  {" .. totalColor .. "}%.1f%%",
		("%" .. (ratioW + fileW - 6) .. "s"):format(("%d/%d"):format(totalCovered, totalExecutable)), totalPercent)
end

---@param reports lde.CoverageReport[]
---@param jsonPath string
local function writeCoverageJson(reports, jsonPath)
	local totalExecutable, totalCovered = 0, 0
	for _, r in ipairs(reports) do
		totalExecutable += r.totalExecutable
		totalCovered += r.totalCovered
	end
	const data = {
		version = 1,
		totalExecutable = totalExecutable,
		totalCovered = totalCovered,
		percent = totalExecutable > 0 and totalCovered / totalExecutable * 100 or 0,
		packages = reports,
	}
	const content = json.encode(data)
	if not content then
		ansi.printf("{red}Failed to encode coverage JSON")
		return
	end
	if not fs.write(jsonPath, content) then
		ansi.printf("{red}Failed to write %s", jsonPath)
		return
	end
	ansi.printf("{cyan}Coverage JSON written to %s", jsonPath)
end

---@param results lde.TestResults
local function printCoverageNotice(results)
	if results.external and not results.coverageRan then
		ansi.printf("  {yellow}Coverage is not supported for rockspec (busted) tests")
	end
end

-- The watcher covers src/, tests/, and the package root (non-recursive, lde.json/build.lua only) so target/ churn never triggers a re-run.
---@param filters string[]
---@param coverage boolean?
local function runWatch(filters, coverage)
	local dirty = false
	const watchers = {}

	---@param dir string
	---@param recursive boolean
	---@param filter? fun(name: string): boolean
	local function addWatch(dir, recursive, filter)
		if not fs.isdir(dir) then return end
		const watcher = fs.watch(dir, function(_event, name)
			if not filter or filter(name) then dirty = true end
		end, { recursive = recursive })
		if not watcher then
			lde.error.raise("Failed to watch: " .. dir)
		end
		watchers[#watchers + 1] = watcher
	end

	const configFiles = function(name)
		return name == "lde.json" or name == "build.lua"
	end

	local package = lde.Package.open()
	if package then
		addWatch(package:getSrcDir(), true)
		addWatch(path.join(package:getDir(), "tests"), true)
		addWatch(package:getDir(), false, configFiles)
	else
		local cwd = env.cwd()
		for _, relativePath in ipairs(fs.scan(cwd, "**" .. path.separator .. "lde.json")) do
			local pkgDir = path.dirname(path.join(cwd, relativePath))
			local pkg = lde.Package.open(pkgDir)
			if pkg and fs.isdir(path.join(pkgDir, "tests")) then
				addWatch(pkg:getSrcDir(), true)
				addWatch(path.join(pkgDir, "tests"), true)
				addWatch(pkgDir, false, configFiles)
			end
		end
	end

	if #watchers == 0 then
		lde.error.raise("No packages with tests found", {
			hint = "Add tests/*.test.lua to a package to get started.",
		})
	end

	local spawnArgs = { "test" }
	if coverage then spawnArgs[#spawnArgs + 1] = "--coverage" end
	for _, f in ipairs(filters) do spawnArgs[#spawnArgs + 1] = f end

	local function spawnChild()
		local execPath = env.execPath() ---@cast execPath -nil
		local child, err = process.spawn(execPath, spawnArgs, { stdout = "inherit", stderr = "inherit" })
		if not child then
			ansi.printf("{red}Error: %s", tostring(err))
		end
		return child
	end

	local child = spawnChild()

	while true do
		if child then child:wait() end
		ansi.printf("{cyan}Watching for changes...")

		dirty = false
		while not dirty do
			for _, watcher in ipairs(watchers) do watcher.poll() end
			if not dirty then sleep(100) end
		end

		ansi.printf("{cyan}Change detected, running tests...")
		child = spawnChild()
	end
end

---@param args clap.Args
local function test(args)
	const watch = args:flag("watch")
	local coverage = args:flag("coverage")
	local jobs = tonumber(args:option("jobs") or "") or defaultJobs()
	-- Hidden shard mode: run exactly one file and record its results for the parent.
	const shardFile = args:option("shard-file")
	const shardResults = args:option("shard-results")
	-- Coverage collection is in-process (a line hook per guest state), so sharded
	-- runs cannot merge it; --coverage and --verbose always run files sequentially.
	if coverage or lde.isVerbose then jobs = 1 end
	-- --json <file> writes the coverage report as JSON (implies --coverage).
	const resultsOut = args:option("results")
	local jsonOut = args:option("json")
	if not jsonOut and args:flag("json") then jsonOut = "coverage.json" end
	if jsonOut then coverage = true end

	args:flag("") -- consume the `--` separator if present
	local filters = {}
	while true do
		const v = args:pop()
		if not v then break end
		filters[#filters + 1] = v
	end

	if watch then
		runWatch(filters, coverage)
		return
	end

	local package = lde.Package.open()

	if shardFile and shardResults and package then
		const results = package:runTests(nil, { shardFile }, { coverage = false, jobs = 1, isShard = true })
		fs.write(shardResults, json.encode({ files = results.files, error = results.error }))
		return
	end

	print()

	if not package then
		local cwd = env.cwd()
		local hadFailures = false
		local totalPassed = 0
		local totalFailures = 0
		local totalSkipped = 0

		local packages = {}
		local coverageReports = {} ---@type lde.CoverageReport[]
		for _, relativePath in ipairs(fs.scan(cwd, "**" .. path.separator .. "lde.json")) do
			-- Hidden dirs (.git, .fuzz, ...) anywhere in the path are VCS internals or scratch, not packages.
			if relativePath:match("^%.[^/\\\\]*[/\\\\]") or relativePath:match("[/\\\\]%.[^/\\\\]*[/\\\\]") then goto continue end
			local configPath = path.join(cwd, relativePath)
			local pkgDir = path.dirname(configPath)
			if not fs.isdir(path.join(pkgDir, "tests")) then goto continue end
			local pkg = lde.Package.open(pkgDir)
			if pkg then
				packages[#packages + 1] = pkg
			end
			::continue::
		end

		-- Rockspec packages whose test spec lives in the rockspec; skip ones with lde.json (handled above).
		for _, relativePath in ipairs(fs.scan(cwd, "**" .. path.separator .. "*.rockspec")) do
			if relativePath:match("^%.[^/\\\\]*[/\\\\]") or relativePath:match("[/\\\\]%.[^/\\\\]*[/\\\\]") then goto continue end
			local configPath = path.join(cwd, relativePath)
			local pkgDir = path.dirname(configPath)
			if fs.exists(path.join(pkgDir, "lde.json")) then goto continue end
			if not (fs.isdir(path.join(pkgDir, "spec")) or fs.exists(path.join(pkgDir, ".busted"))) then
				goto continue
			end
			local pkg = lde.Package.open(pkgDir)
			if pkg then
				packages[#packages + 1] = pkg
			end
			::continue::
		end

		if #packages == 0 then
			lde.error.raise("No packages with tests found", {
				hint = "Add tests/*.test.lua to a package to get started.",
			})
		end

		ansi.printf("{white}Running tests from {cyan}%d {white}%s",
			#packages, #packages == 1 ? "package" : "packages")
		print()

		-- Packages run in their own `lde test` processes when there is more than
		-- one: the two heavy packages (lde, lde-core) dominate the suite, and
		-- nothing in them shares state except the global caches, which are
		-- materialized atomically. Coverage is in-process, so it stays sequential.
		if jobs > 1 and #packages > 1 and not coverage and not lde.isVerbose then
			const packageWorkers = math.min(#packages, math.max(2, math.floor(jobs / 4)))
			const fileJobs = math.max(1, math.floor(jobs / packageWorkers))
			const scratch = path.join(env.tmpdir(), "lde-pkgs-" .. tostring({}):match("0x(%x+)$"))
			fs.mkdirAll(scratch)
			const execPath = assert(env.execPath(), "no executable path")

			---@type { name: string, child: process.Child?, results: string, output: string? }[]
			const running = {}
			---@type { name: string, output: string, total: integer, failures: integer, skipped: integer, error: string? }[]
			const finished = {}
			local next = 1
			local hadFailures = false
			local totalPassed, totalFailures, totalSkipped = 0, 0, 0

			---@param pkg lde.Package
			---@param index integer
			---@return { name: string, child: process.Child?, results: string, output: string? }
			local function startPackage(pkg, index)
				const resultsFile = path.join(scratch, index .. ".json")
				local childArgs = { "-C", pkg:getDir(), "test", "--results", resultsFile, "--jobs", tostring(fileJobs) }
				if lde.global.getDir() ~= lde.global.getUserDir() then
					childArgs[#childArgs + 1] = "--tree"
					childArgs[#childArgs + 1] = lde.global.getDir()
				end
				for _, f in ipairs(filters) do childArgs[#childArgs + 1] = f end
				local child = process.spawn(execPath, childArgs, { stdout = "pipe", stderr = "pipe" })
				if not child then
					fs.write(resultsFile, json.encode({ total = 0, failures = 1, skipped = 0 }))
				end
				return { name = pkg:getName(), child = child, results = resultsFile }
			end

			local function startNext()
				if next > #packages then return end
				const entry = startPackage(packages[next], next)
				entry.output = nil
				running[#running + 1] = entry
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
						if fs.exists(entry.results) then
							const okDecode, parsed = pcall(json.decode, fs.read(entry.results) or "")
							if okDecode and type(parsed) == "table" then decoded = parsed end
						end
						const skipped = (decoded and decoded.skipped) or 0
						const failures = (decoded and decoded.failures) or (decoded and 0 or 1)
						const total = (decoded and decoded.total) or 0
						finished[#finished + 1] = {
							name = entry.name,
							output = output,
							total = total,
							failures = failures,
							skipped = skipped,
							error = decoded and decoded.error or (not decoded and "test process failed" or nil),
						}
						table.remove(running, i)
					end
				end
			end

			while next <= #packages and #running < packageWorkers do startNext() end
			while #running > 0 do
				reapFinished()
				while next <= #packages and #running < packageWorkers do startNext() end
				if #running > 0 then sleep(5) end
			end

			-- Results are printed in package order once every package has finished,
			-- so a slow package never delays reporting of the ones after it.
			for _, entry in ipairs(finished) do
				ansi.printf("{gray}%s", entry.name)
				print()
				io.write(entry.output)
				if not entry.error and entry.output == "" then print() end
				if entry.error then
					ansi.printf("  {red}%s", entry.error)
					hadFailures = true
					totalFailures = totalFailures + 1
				else
					totalPassed = totalPassed + entry.total - entry.failures
					totalFailures = totalFailures + entry.failures
					totalSkipped = totalSkipped + entry.skipped
					if entry.failures > 0 then hadFailures = true end
				end
			end

			fs.rmdir(scratch)

			print()
			printSummary(totalFailures, totalPassed, totalPassed + totalFailures, totalSkipped)
			if hadFailures then os.exit(1) end
			return
		end

		-- A run where a filter matched nothing anywhere is a typo, not a pass.
		local anyMatched = false

		for _, pkg in ipairs(packages) do
			ansi.printf("{gray}%s", pkg:getName())
			print()
			local reporter = makeReporter(pkg:getDir())
			-- Run package relative to its own dir so you get identical behavior as if you ran the individual package's tests.
			env.chdir(pkg:getDir())
			local results = pkg:runTests(reporter, filters, { coverage = coverage, jobs = jobs })
			env.chdir(cwd)
			if results.error then
				ansi.printf("  {red}%s", results.error)
				hadFailures = true
				totalFailures += 1
			elseif results.external then
				anyMatched = true
				if results.exitCode ~= 0 then
					ansi.printf("  {red}Tests: failed (exit %s)", tostring(results.exitCode))
					hadFailures = true
					totalFailures += 1
				else
					ansi.printf("  {green}Tests: passed")
					totalPassed = totalPassed + 1
				end
			elseif #results.files == 0 then
				-- Per-package miss is only an error when no package matched anywhere (checked below).
				if #filters > 0 then
					ansi.printf("  {gray}No files matched")
				else
					ansi.printf("  {gray}No tests found")
				end
			else
				anyMatched = true
				printFileErrors(results, pkg:getDir())
				totalPassed += (results.total - results.failures)
				totalFailures += results.failures
				totalSkipped += (results.skipped or 0)
				if results.failures > 0 then hadFailures = true end
			end
			if coverage then
				if results.coverage then
					printCoverage(pkg, results.coverage)
					coverageReports[#coverageReports + 1] = coverageReport(pkg, results.coverage)
				else
					printCoverageNotice(results)
				end
			end
			print()
		end

		if jsonOut and #coverageReports > 0 then
			writeCoverageJson(coverageReports, jsonOut)
			print()
		end

		local totalTests = totalPassed + totalFailures
		printSummary(totalFailures, totalPassed, totalTests, totalSkipped)

		-- A typo'd filter (no match anywhere) and a run with zero tests must both fail.
		if #filters > 0 and not anyMatched then
			lde.error.raise("No test files match: " .. table.concat(filters, ", "))
		end
		if not hadFailures and totalTests == 0 then
			lde.error.raise("No tests found in any package (expected *.test.lua files)")
		end

		if hadFailures then
			os.exit(1)
		end

		return
	end

	local reporter = makeReporter(package:getDir())
	local results = package:runTests(reporter, filters, { coverage = coverage, jobs = jobs })
	if resultsOut then
		fs.write(resultsOut, json.encode({
			total = results.total,
			failures = results.failures,
			skipped = results.skipped,
			error = results.error,
		}))
	end
	if results.error then
		lde.error.raise(results.error)
	elseif results.external then
		-- External runners (busted) print their own results; lde reports the verdict so the exit code matches the suite's.
		if results.exitCode ~= 0 then
			ansi.printf("{red}Tests: failed (exit %s)", tostring(results.exitCode))
		else
			ansi.printf("{green}Tests: passed")
		end
		if coverage then printCoverageNotice(results) end
		print()
		os.exit(results.exitCode ~= 0 and 1 or 0)
		return
	elseif #results.files == 0 then
		-- A filter matching no file, or an empty/typo'd tests/ dir, must not pass silently.
		if #filters > 0 then
			lde.error.raise("No test files match: " .. table.concat(filters, ", "))
		end
		lde.error.raise("No tests found in: " .. package:getTestDir() .. " (expected *.test.lua files)")
	else
		printFileErrors(results, package:getDir())
	end
	print()
	printSummary(results.failures, results.total - results.failures, results.total, results.skipped or 0)
	if coverage then
		if results.coverage then
			printCoverage(package, results.coverage)
			if jsonOut then
				writeCoverageJson({ coverageReport(package, results.coverage) }, jsonOut)
				print()
			end
		else
			printCoverageNotice(results)
		end
	end
	if results.failures > 0 then
		os.exit(1)
	end
end

return test
