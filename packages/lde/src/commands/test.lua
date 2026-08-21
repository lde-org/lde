local fs = require("fs")
local path = require("path")
local ansi = require("ansi")
local env = require("env")
local process = require("process")
local ffi = require("ffi")

local highlight = require("readline.highlight")

local lde = require("lde-core")

-- Cross-platform sleep used to poll the file watchers in --watch mode.
local sleep
if jit.os == "Windows" then
	pcall(ffi.cdef, "void Sleep(unsigned long dwMilliseconds);")
	sleep = function(ms) ffi.C.Sleep(ms) end
else
	pcall(ffi.cdef, "int usleep(unsigned int usec);")
	sleep = function(ms) ffi.C.usleep(ms * 1000) end
end

---@param packageDir string
---@param msg string
local function makeRelative(packageDir, msg)
	-- Escape pattern magic characters so a path with "-", ".", etc. matches literally.
	local prefix = packageDir .. path.separator
	prefix = prefix:gsub("([^%w])", "%%%1")
	return (string.gsub(msg, prefix, ""))
end

-- Lines of context shown above and below the failing line.
local CONTEXT = 2

-- Split source text into lines (dropping the empty entry left by a final newline).
---@param src string
---@return string[]
local function splitLines(src)
	local lines = {}
	local pos = 1
	while true do
		local nl = src:find("\n", pos, true)
		if nl then
			lines[#lines + 1] = src:sub(pos, nl - 1)
			pos = nl + 1
		else
			lines[#lines + 1] = src:sub(pos)
			break
		end
	end
	if #lines > 1 and lines[#lines] == "" then lines[#lines] = nil end
	return lines
end

---@param line string
---@return string
local function expandTabs(line)
	return (line:gsub("\t", "    "))
end

-- Assertion names, longest first so e.g. "greaterEqual" wins over "equal".
local ASSERT_NAMES = {
	"greaterEqual", "lessEqual", "notEqual", "deepEqual",
	"includes", "truthy", "falsy", "greater", "less", "match", "equal",
}

--- Search a line for the assertion call (or a variable named in the error
--- message) so the caret points at what actually failed.
---@param line string
---@param msg string?
---@return number col, number len
local function findCaretCol(line, msg)
	---@param word string
	---@return integer?
	local function findWord(word)
		local i = 1
		while i <= #line do
			local s = line:find(word, i, true)
			if not s then return nil end
			local e = s + #word
			local before = s > 1 and line:sub(s - 1, s - 1) or ""
			local after = line:sub(e, e)
			if not before:match("[%w_]") and not after:match("[%w_]") then
				return s
			end
			i = e
		end
	end

	-- Failing assertion call, e.g. `test.deepEqual(a, b)`.
	for _, name in ipairs(ASSERT_NAMES) do
		local i = 1
		while i <= #line do
			local s = line:find(name, i, true)
			if not s then break end
			local e = s + #name
			local before = s > 1 and line:sub(s - 1, s - 1) or ""
			if not before:match("[%w_]") then
				local j = e
				while j <= #line and line:sub(j, j):match("%s") do j = j + 1 end
				if line:sub(j, j) == "(" then
					return s, #name
				end
			end
			i = e
		end
	end

	-- A variable/field called out in a runtime error, e.g.
	-- `attempt to index a nil value (local 'x')`.
	if msg then
		local var = msg:match("^.*'([^']+)'")
		if var then
			local s = findWord(var)
			if s then return s, #var end
		end
	end

	-- Fallback: start of the statement.
	local first = line:find("%S")
	return first or 1, 1
end

-- Resolve the file to read for a failure. The path in the error prefix uses
-- short_src and may be truncated (".../x") for long paths, so fall back to the
-- test file the runner knows it was executing.
---@param pkgDir string
---@param msgFile string
---@param knownFile? string
---@return string? actual, string? src
local function resolveSource(pkgDir, msgFile, knownFile)
	local candidates = {}
	msgFile = msgFile:gsub("^@", "")
	if not msgFile:match("^%.%.%.") then
		candidates[#candidates + 1] = msgFile
		if not (msgFile:match("^/") or msgFile:match("^%a:[/\\]")) then
			candidates[#candidates + 1] = path.join(pkgDir, msgFile)
		end
	end
	if knownFile then candidates[#candidates + 1] = knownFile end
	for _, c in ipairs(candidates) do
		if fs.exists(c) then
			local src = fs.read(c)
			if src then return c, src end
		end
	end
	return nil, nil
end

-- Print the gutter + highlighted code window for a failing line, with a caret
-- placed directly under the failing line. The caret line keeps a blank gutter
-- (a gap where the line number would be) so the arrows have vertical room.
---@param src string
---@param line number
---@param msg string?
local function printSnippet(src, line, msg)
	local lines = splitLines(src)
	if line < 1 or line > #lines then return end

	local startLine = math.max(1, line - CONTEXT)
	local endLine   = math.min(#lines, line + CONTEXT)
	local width     = #tostring(endLine)
	local indent    = "     "
	local bar       = ansi.colorize("gray", "│")
	local pad       = string.rep(" ", width)

	-- Code lines with the gutter prefix: indent + right-aligned number +
	-- separator + bar + separator. Every other line (bars, caret) reuses the
	-- same prefix so the gutter stays horizontally aligned.
	local prefix = indent .. pad .. " " .. bar .. " "
	local gutter = {}
	for ln = startLine, endLine do
		local num = string.rep(" ", width - #tostring(ln)) .. tostring(ln)
		local code = highlight(expandTabs(lines[ln]))
		gutter[ln] = indent .. ansi.colorize("gray", num) .. " " .. bar .. " " .. code
	end

	local failing = expandTabs(lines[line])
	local col, len = findCaretCol(failing, msg)
	local caret = ansi.format("{red}{bold}%s{reset}", string.rep("^", len))

	print(indent .. pad .. " " .. bar)
	for ln = startLine, line - 1 do print(gutter[ln]) end
	print(gutter[line])
	print(prefix .. string.rep(" ", col - 1) .. caret)
	for ln = line + 1, endLine do print(gutter[ln]) end
	print(indent .. pad .. " " .. bar)
end

-- Print a failure message, followed by a source snippet when the failing
-- line can be located.
---@param pkgDir string
---@param err string
---@param knownFile? string
local function printError(pkgDir, err, knownFile)
	local mfile, mline, rest = err:match("^(.*):(%d+): (.*)$")
	if not mfile then
		ansi.printf("     {red}%s", makeRelative(pkgDir, err))
		return
	end
	local line = tonumber(mline) ---@cast line -nil
	local actual, src = resolveSource(pkgDir, mfile, knownFile)
	-- If the fallback file doesn't contain the failing line, the line belongs to
	-- a different (unresolvable, truncated) file — show the path as reported
	-- instead of pairing a wrong path with the line.
	if src then
		local lines = splitLines(src)
		if line < 1 or line > #lines then actual, src = nil, nil end
	end
	ansi.printf("     {red}%s", makeRelative(pkgDir, actual or mfile) .. ":" .. line .. ": " .. rest)
	if actual and src then
		printSnippet(src, line, rest)
	end
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
			return ansi.progress(name)
		end,
		onPass = function(name, handle)
			handle:done(name)
		end,
		onFail = function(name, err, handle, file)
			handle:fail(name)
			printError(pkgDir, err or "unknown error", file)
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
			local testDir = results.package and results.package:getTestDir() or pkgDir
			printError(pkgDir, file.error, path.join(testDir, file.file))
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
---@return string
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

--- Build a per-file coverage report (display paths, sorted worst-first). Shared
--- by the text printer and the --json emitter so both see identical data.
---@param pkg lde.Package
---@param coverage lde.Coverage
---@return lde.CoverageReport
local function coverageReport(pkg, coverage)
	local files, totalExecutable, totalCovered = coverage:compute()

	local pkgDir = pkg:getDir()
	local targetPrefix = path.join("target", pkg:getName()) .. path.separator

	---@type lde.CoverageFileRow[]
	local rows = {}
	for _, f in ipairs(files) do
		local rel = path.relative(pkgDir, f.file) or f.file
		if rel:sub(1, #targetPrefix) == targetPrefix then
			rel = path.join("src", rel:sub(#targetPrefix + 1))
		end
		-- Display paths with forward slashes on every platform; path.relative
		-- and path.join use the OS separator (backslashes on Windows).
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

-- Print a per-file line coverage report. Files show as src/ paths (modules
-- load from target/<name>, the built copy of src/), sorted worst-first.
---@param pkg lde.Package
---@param coverage lde.Coverage
local function printCoverage(pkg, coverage)
	local report = coverageReport(pkg, coverage)
	local rows = report.files
	if #rows == 0 then
		ansi.printf("  {yellow}Coverage: no source files were loaded")
		return
	end

	local totalExecutable, totalCovered = report.totalExecutable, report.totalCovered

	-- Column widths: files left-aligned (min 38 chars), the covered/total
	-- ratio right-aligned as a unit, so "lines" and the percentage land in
	-- the same column on every row and on the Total line.
	local fileW = 38
	local covW, totW = 1, 1
	for _, r in ipairs(rows) do
		fileW = math.max(fileW, #r.file)
		covW = math.max(covW, #tostring(r.covered))
		totW = math.max(totW, #tostring(r.executable))
	end
	local ratioW = covW + 1 + totW
	-- Widest row: 2 indent + file + 1 + ratio + 1 + "lines" + 2 + "100.0%".
	local sepW = fileW + ratioW + 17

	print()
	ansi.printf("  {bold}Coverage")
	print("  " .. ansi.colorize("gray", string.rep("─", sepW)))
	for _, r in ipairs(rows) do
		-- The color token is spliced into the format string at runtime so
		-- ansi.format resolves it; {%s} would survive gsub and print literally.
		local color = percentColor(r.percent)
		ansi.printf("  {gray}%-" .. fileW .. "s{reset} %" .. ratioW .. "s {gray}lines{reset}  {" .. color .. "}%.1f%%",
			r.file, ("%d/%d"):format(r.covered, r.executable), r.percent)
	end
	print("  " .. ansi.colorize("gray", string.rep("─", sepW)))
	local totalPercent = totalExecutable > 0 and totalCovered / totalExecutable * 100 or 0
	local totalColor = percentColor(totalPercent)
	-- Right-align the Total's ratio with the rows ("  Total: " is 9 chars).
	ansi.printf("  Total: %s {gray}lines{reset}  {" .. totalColor .. "}%.1f%%",
		("%" .. (ratioW + fileW - 6) .. "s"):format(("%d/%d"):format(totalCovered, totalExecutable)), totalPercent)
end

--- Write one or more per-package coverage reports as JSON for programmatic
--- analysis (CI, dashboards, finding untested modules). The shape mirrors the
--- text report: files sorted worst-first, per-package and combined totals.
---@param reports lde.CoverageReport[]
---@param jsonPath string
local function writeCoverageJson(reports, jsonPath)
	local json = require("json")
	local totalExecutable, totalCovered = 0, 0
	for _, r in ipairs(reports) do
		totalExecutable = totalExecutable + r.totalExecutable
		totalCovered = totalCovered + r.totalCovered
	end
	local data = {
		version = 1,
		totalExecutable = totalExecutable,
		totalCovered = totalCovered,
		percent = totalExecutable > 0 and totalCovered / totalExecutable * 100 or 0,
		packages = reports,
	}
	local content = json.encode(data)
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

-- Print a notice when coverage was requested but the runner can't provide it.
---@param results lde.TestResults
local function printCoverageNotice(results)
	if results.external and not results.coverageRan then
		ansi.printf("  {yellow}Coverage is not supported for rockspec (busted) tests")
	end
end

--- Re-run `lde test` whenever the project's source or tests change.
--- The watcher only covers src/, tests/, and the package root (non-recursive,
--- filtered to lde.json/build.lua) so the target/ churn from running the tests
--- never triggers a re-run.
---@param filters string[]
---@param coverage boolean?
local function runWatch(filters, coverage)
	local dirty = false
	local watchers = {}

	---@param dir string
	---@param recursive boolean
	---@param filter? fun(name: string): boolean
	local function addWatch(dir, recursive, filter)
		if not fs.isdir(dir) then return end
		local watcher = fs.watch(dir, function(_event, name)
			if not filter or filter(name) then dirty = true end
		end, { recursive = recursive })
		if not watcher then
			lde.error.raise("Failed to watch: " .. dir)
		end
		watchers[#watchers + 1] = watcher
	end

	local configFiles = function(name)
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
		ansi.printf("{yellow}No packages with tests found")
		return
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
	local watch = args:flag("watch")
	local coverage = args:flag("coverage")
	-- --json <file> writes the coverage report as JSON (implies --coverage).
	local jsonOut = args:option("json")
	if not jsonOut and args:flag("json") then jsonOut = "coverage.json" end
	if jsonOut then coverage = true end

	-- Collect remaining positional args as test file filter globs
	local filters = {}
	while true do
		local v = args:pop()
		if not v then break end
		filters[#filters + 1] = v
	end

	if watch then
		runWatch(filters, coverage)
		return
	end

	local package = lde.Package.open()

	print()

	-- Running outside of a package, run tests for all packages inside of cwd
	if not package then
		local cwd = env.cwd()
		local hadFailures = false
		local totalPassed = 0
		local totalFailures = 0
		local totalSkipped = 0

		local packages = {}
		local coverageReports = {} ---@type lde.CoverageReport[]
		for _, relativePath in ipairs(fs.scan(cwd, "**" .. path.separator .. "lde.json")) do
			-- Skip hidden directories (.git, .fuzz, .shotgun, ...) anywhere in
			-- the path: VCS internals and generated scratch dirs are not packages.
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

		-- Rockspec-based packages (e.g. LuaRocks projects) whose test
		-- specification lives in the rockspec; skip ones that also have an
		-- lde.json (already handled above) and require a busted-style layout.
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
			ansi.printf("{yellow}No packages with tests found")
			return
		end

		ansi.printf("{white}Running tests from {cyan}%d {white}%s",
			#packages, #packages == 1 and "package" or "packages")
		print()

		for _, pkg in ipairs(packages) do
			ansi.printf("{gray}%s", pkg:getName())
			print()
			local reporter = makeReporter(pkg:getDir())
			local results = pkg:runTests(reporter, filters, { coverage = coverage })
			if results.error then
				ansi.printf("  {red}%s", results.error)
				hadFailures = true
				totalFailures = totalFailures + 1
			elseif results.external then
				-- External runners (busted) print their own results.
				if results.exitCode ~= 0 then
					ansi.printf("  {red}Tests: failed (exit %s)", tostring(results.exitCode))
					hadFailures = true
					totalFailures = totalFailures + 1
				else
					ansi.printf("  {green}Tests: passed")
					totalPassed = totalPassed + 1
				end
			elseif #results.files == 0 and #filters > 0 then
				ansi.printf("  {gray}No files matched")
			else
				printFileErrors(results, pkg:getDir())
				totalPassed = totalPassed + (results.total - results.failures)
				totalFailures = totalFailures + results.failures
				totalSkipped = totalSkipped + (results.skipped or 0)
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

		if hadFailures then
			os.exit(1)
		end

		return
	end

	local reporter = makeReporter(package:getDir())
	local results = package:runTests(reporter, filters, { coverage = coverage })
	if results.error then
		lde.error.raise(results.error)
	elseif results.external then
		-- External runners (busted) print their own results; lde just reports
		-- the verdict so the exit code matches the suite's.
		if results.exitCode ~= 0 then
			ansi.printf("{red}Tests: failed (exit %s)", tostring(results.exitCode))
		else
			ansi.printf("{green}Tests: passed")
		end
		if coverage then printCoverageNotice(results) end
		print()
		os.exit(results.exitCode ~= 0 and 1 or 0)
		return
	elseif #results.files == 0 and #filters > 0 then
		ansi.printf("  {gray}No files matched")
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
