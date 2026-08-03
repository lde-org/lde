local fs = require("fs")
local path = require("path")
local ansi = require("ansi")
local env = require("env")
local process = require("process")
local ffi = require("ffi")

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
	local prefix = packageDir .. path.separator
	return (string.gsub(msg, prefix, ""))
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
		onFail = function(name, err, handle)
			handle:fail(name)
			ansi.printf("     {red}%s", makeRelative(pkgDir, err or "unknown error"))
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
			ansi.printf("    {red}%s", makeRelative(pkgDir, file.error))
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
