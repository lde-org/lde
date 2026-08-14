local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")

local ldecli = require("tests.lib.ldecli")

test.it("lde test --coverage reports per-file line coverage", function()
	local tmpDir = path.join(env.tmpdir(), "lde-coverage-test")
	fs.rmdir(tmpDir)
	fs.mkdir(tmpDir)

	fs.write(path.join(tmpDir, "lde.json"), json.encode({ name = "cov-demo", version = "0.1.0" }))

	-- One function the test exercises, one it never calls — so the report must
	-- show partial coverage of src/init.lua.
	fs.mkdir(path.join(tmpDir, "src"))
	fs.write(path.join(tmpDir, "src", "init.lua"), [[
local M = {}

function M.covered()
	return 42
end

function M.uncovered()
	return "never called"
end

return M
]])

	-- A second file whose executable counts have more digits (32/92 vs 7/8),
	-- so the 'lines' column would drift if the counts weren't right-aligned.
	local util = { "local M = {}" }
	for i = 1, 30 do
		util[#util + 1] = ("function M.f%d()"):format(i)
		util[#util + 1] = ("\treturn %d"):format(i)
		util[#util + 1] = "end"
	end
	util[#util + 1] = "return M"
	fs.write(path.join(tmpDir, "src", "util.lua"), table.concat(util, "\n"))

	fs.mkdir(path.join(tmpDir, "tests"))
	local body = {
		"local test = require(\"lde-test\")",
		"local cov = require(\"cov-demo\")",
		"local util = require(\"cov-demo.util\")",
		"",
		"test.it(\"covers part of the module\", function()",
		"\ttest.equal(cov.covered(), 42)",
	}
	-- Exercise the first 10 of 30 functions so the file is partially covered.
	for i = 1, 10 do
		body[#body + 1] = ("\ttest.equal(util.f%d(), %d)"):format(i, i)
	end
	body[#body + 1] = "end)"
	fs.write(path.join(tmpDir, "tests", "main.test.lua"), table.concat(body, "\n"))

	local ok, out = ldecli({ "test", "--coverage" }, tmpDir)
	test.truthy(ok, "lde test --coverage failed: " .. tostring(out))
	-- GitHub Actions forces ANSI colors on even when stdout is a pipe, so strip
	-- escape sequences before matching on content and column layout.
	out = out:gsub("\27%[[0-9;]*m", "")
	test.includes(out, "Coverage")
	-- Modules load from target/<name> but are shown as src/ paths.
	test.includes(out, "src/init.lua")
	test.includes(out, "src/util.lua")
	local covered, executable = out:match("Total:%s*(%d+)/(%d+)")
	test.truthy(covered and executable, "expected a 'Total: N/M' line, got:\n" .. tostring(out))
	test.truthy(tonumber(covered) > 0, "expected some covered lines")
	test.truthy(tonumber(covered) < tonumber(executable), "expected partial coverage")

	-- The 'lines' label must start in the same column on every row (each file
	-- row plus the Total line), which also pins the percentage column. Match
	-- the space-prefixed label so a file path containing "lines" can't confuse
	-- the column comparison.
	local report = out:match("Coverage\r?\n(.*)$")
	test.truthy(report, "expected a coverage report")
	local col
	local aligned = true
	for line in report:gmatch("[^\r\n]+") do
		local at = line:find(" lines", 1, true)
		if at then
			if col and at ~= col then aligned = false end
			col = col or at
		end
	end
	test.truthy(col, "expected a 'lines' label in the coverage report")
	test.truthy(aligned, "coverage 'lines' column is misaligned:\n" .. tostring(out))

	fs.rmdir(tmpDir)
end)

test.it("lde test --coverage --json writes programmatically checkable report data", function()
	local tmpDir = path.join(env.tmpdir(), "lde-coverage-json-test")
	fs.rmdir(tmpDir)
	fs.mkdir(tmpDir)

	fs.write(path.join(tmpDir, "lde.json"), json.encode({ name = "covjson", version = "0.1.0" }))
	fs.mkdir(path.join(tmpDir, "src"))
	fs.write(path.join(tmpDir, "src", "init.lua"), [[
local M = {}
function M.used()
	return 1
end
function M.unused()
	return 2
end
return M
]])
	fs.mkdir(path.join(tmpDir, "tests"))
	fs.write(path.join(tmpDir, "tests", "main.test.lua"), [[
local t = require("lde-test")
local m = require("covjson")
t.it("uses part of the module", function()
	t.equal(m.used(), 1)
end)
]])

	local jsonPath = path.join(tmpDir, "cov.json")
	fs.delete(jsonPath)

	local ok, out = ldecli({ "test", "--coverage", "--json", jsonPath }, tmpDir)
	test.truthy(ok, "lde test --coverage --json failed: " .. tostring(out))
	test.truthy(fs.exists(jsonPath), "coverage JSON not written")

	local data = json.decode(fs.read(jsonPath))
	test.truthy(data, "coverage JSON must decode")
	test.equal(data.version, 1)
	test.equal(#data.packages, 1)
	test.equal(data.packages[1].package, "covjson")

	-- The fixture has 6 executable lines; only the used() body is hit.
	local pkg = data.packages[1]
	test.truthy(pkg.totalExecutable > 0)
	test.truthy(pkg.totalCovered > 0)
	test.truthy(pkg.totalCovered < pkg.totalExecutable, "expected partial coverage")
	test.equal(#pkg.files, 1)
	test.equal(pkg.files[1].file, "src/init.lua")
	test.equal(pkg.files[1].covered, pkg.totalCovered)
	test.truthy(pkg.percent > 0 and pkg.percent < 100)

	fs.rmdir(tmpDir)
end)
