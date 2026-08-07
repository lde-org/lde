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

	fs.mkdir(path.join(tmpDir, "tests"))
	fs.write(path.join(tmpDir, "tests", "main.test.lua"), [[
local test = require("lde-test")
local cov = require("cov-demo")

test.it("covers part of the module", function()
	test.equal(cov.covered(), 42)
end)
]])

	local ok, out = ldecli({ "test", "--coverage" }, tmpDir)
	test.truthy(ok, "lde test --coverage failed: " .. tostring(out))
	test.includes(out, "Coverage")
	-- Modules load from target/<name> but are shown as src/ paths.
	test.includes(out, "src/init.lua")
	local covered, executable = out:match("Total: (%d+)/(%d+)")
	test.truthy(covered and executable, "expected a 'Total: N/M' line, got:\n" .. tostring(out))
	test.truthy(tonumber(covered) > 0, "expected some covered lines")
	test.truthy(tonumber(covered) < tonumber(executable), "expected partial coverage")

	fs.rmdir(tmpDir)
end)
