local fs = require("fs")
local path = require("path")
local ansi = require("ansi")
local env = require("env")

local lpm = require("lpm-core")

---@param packageDir string
---@param msg string
local function makeRelative(packageDir, msg)
	local prefix = packageDir .. path.separator
	return (string.gsub(msg, prefix, ""))
end

---@param results lpm.TestResults
---@param indent string?
---@return boolean hadFailures
local function printResults(results, indent)
	if results.error then
		error(results.error)
	end

	indent = indent or ""
	local pkgDir = results.package:getDir()

	for _, file in ipairs(results.files) do
		if file.error then
			ansi.printf(indent .. " {red}FAIL {white}%s", file.file)
			ansi.printf(indent .. "   {red}%s", makeRelative(pkgDir, file.error))
		else
			local fileHasFailures = false
			for _, r in ipairs(file.results) do
				if not r.ok then
					fileHasFailures = true
					break
				end
			end

			if fileHasFailures then
				ansi.printf(indent .. " {red}FAIL {white}%s", file.file)
			else
				ansi.printf(indent .. " {green}PASS {white}%s", file.file)
			end

			for _, r in ipairs(file.results) do
				if r.ok then
					ansi.printf(indent .. "   {green}\xE2\x9C\x93 {gray}%s", r.name)
				else
					ansi.printf(indent .. "   {red}\xE2\x9C\x97 %s", r.name)
					ansi.printf(indent .. "     {red}%s", makeRelative(pkgDir, r.error or "unknown error"))
				end
			end
		end

		print()
	end

	return results.failures > 0
end

---@param failures number
---@param passed number
---@param total number
local function printSummary(failures, passed, total)
	if failures > 0 then
		ansi.printf("{white}Tests:  {red}%d failed{white}, {green}%d passed{white}, {cyan}%d total", failures, passed,
			total)
	else
		ansi.printf("{white}Tests:  {green}%d passed{white}, {cyan}%d total", passed, total)
	end
end

---@param _args clap.Args
local function test(_args)
	local package = lpm.Package.open()

	print()

	-- Running outside of a package, run tests for all packages inside of cwd
	if not package then
		local cwd = env.cwd()
		local hadFailures = false
		local totalPassed = 0
		local totalFailures = 0

		-- Collect results first so we can print the header with totals
		local allResults = {}
		for _, relativePath in ipairs(fs.scan(cwd, "**" .. path.separator .. "lpm.json")) do
			local configPath = path.join(cwd, relativePath)
			local pkg = lpm.Package.open(path.dirname(configPath))
			if pkg then
				local results = pkg:runTests()
				if not results.error then
					allResults[#allResults + 1] = results
					totalPassed = totalPassed + (results.total - results.failures)
					totalFailures = totalFailures + results.failures
				end
			end
		end

		local totalTests = totalPassed + totalFailures
		ansi.printf("{white}Running {cyan}%d {white}%s from {cyan}%d {white}%s",
			totalTests, totalTests == 1 and "test" or "tests",
			#allResults, #allResults == 1 and "package" or "packages")

		print()

		for _, results in ipairs(allResults) do
			ansi.printf("{gray}%s", results.package:getName())
			print()
			if printResults(results, "  ") then
				hadFailures = true
			end
		end

		printSummary(totalFailures, totalPassed, totalTests)

		if hadFailures then
			os.exit(1)
		end

		return
	end

	local results = package:runTests()
	printResults(results)
	printSummary(results.failures, results.total - results.failures, results.total)
	if results.failures > 0 then
		os.exit(1)
	end
end

return test
