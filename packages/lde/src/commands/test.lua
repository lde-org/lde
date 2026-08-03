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
	return line:gsub("\t", "    ")
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
-- marking where the error occurred.
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

	print(indent .. pad .. bar)
	for ln = startLine, endLine do
		local num = string.rep(" ", width - #tostring(ln)) .. tostring(ln)
		local code = highlight(expandTabs(lines[ln]))
		print(indent .. ansi.colorize("gray", num) .. " " .. bar .. " " .. code)
	end

	local failing = expandTabs(lines[line])
	local col, len = findCaretCol(failing, msg)
	local caret = ansi.format("{red}{bold}%s{reset}", string.rep("^", len))
	print(indent .. pad .. " " .. bar .. " " .. string.rep(" ", col - 1) .. caret)

	print(indent .. pad .. bar)
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
	local line = tonumber(mline)
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
	local skipStr = skipped > 0 and ansi.format(", {yellow}%d skipped", skipped) or ""
	if failures > 0 then
		ansi.printf("{white}Tests:  {red}%d failed{white}, {green}%d passed{white}, {cyan}%d total" .. skipStr, failures,
			passed, total)
	else
		ansi.printf("{white}Tests:  {green}%d passed{white}, {cyan}%d total" .. skipStr, passed, total)
	end
end

--- Re-run `lde test` whenever the project's source or tests change.
--- The watcher only covers src/, tests/, and the package root (non-recursive,
--- filtered to lde.json/build.lua) so the target/ churn from running the tests
--- never triggers a re-run.
---@param filters string[]
local function runWatch(filters)
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
			ansi.printf("{red}Failed to watch: %s", dir)
			os.exit(1)
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
	for _, f in ipairs(filters) do spawnArgs[#spawnArgs + 1] = f end

	local function spawnChild()
		local child, err = process.spawn(env.execPath(), spawnArgs, { stdout = "inherit", stderr = "inherit" })
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

	-- Collect remaining positional args as test file filter globs
	local filters = {}
	while true do
		local v = args:pop()
		if not v then break end
		filters[#filters + 1] = v
	end

	if watch then
		runWatch(filters)
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
		for _, relativePath in ipairs(fs.scan(cwd, "**" .. path.separator .. "lde.json")) do
			local configPath = path.join(cwd, relativePath)
			local pkgDir = path.dirname(configPath)
			if not fs.isdir(path.join(pkgDir, "tests")) then goto continue end
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
			local results = pkg:runTests(reporter, filters)
			if results.error then
				ansi.printf("  {red}%s", results.error)
			elseif #results.files == 0 and #filters > 0 then
				ansi.printf("  {gray}No files matched")
			else
				printFileErrors(results, pkg:getDir())
				totalPassed = totalPassed + (results.total - results.failures)
				totalFailures = totalFailures + results.failures
				totalSkipped = totalSkipped + (results.skipped or 0)
				if results.failures > 0 then hadFailures = true end
			end
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
	local results = package:runTests(reporter, filters)
	if results.error then
		ansi.printf("{red}%s", results.error)
	else
		printFileErrors(results, package:getDir())
	end
	print()
	printSummary(results.failures, results.total - results.failures, results.total, results.skipped or 0)
	if results.failures > 0 then
		os.exit(1)
	end
end

return test
