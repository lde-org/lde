local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")

local ldecli = require("tests.lib.ldecli")

-- Strip ANSI escape codes so assertions can match the rendered text.
---@param s string
---@return string
local function strip(s)
	return (s:gsub("\27%[[%d;]*m", ""))
end

--- Create a scratch package with the given test sources in tmpdir.
---@param name string
---@param testSources table<string, string>
---@return string
local function makePackage(name, testSources)
	local dir = path.join(env.tmpdir(), "lde-report-" .. name)
	fs.rmdir(dir)
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), "return true")
	fs.write(path.join(dir, "lde.json"), json.encode({ name = name, version = "0.1.0" }))
	fs.mkdir(path.join(dir, "tests"))
	for fileName, src in pairs(testSources) do
		fs.write(path.join(dir, "tests", fileName), src)
	end
	return dir
end

test.it("assertion failures print a snippet with gutter, highlighting, and caret", function()
	local dir = makePackage("assert", {
		["fail.test.lua"] = 'local test = require("lde-test")\ntest.it("fails", function()\n  test.equal(1, 2)\nend)\n',
	})

	local ok, out = ldecli({ "test" }, dir)
	test.falsy(ok)
	local plain = strip(out or "")

	-- Message uses a package-relative path (even though tmpdir contains "-").
	test.includes(plain, "tests/fail.test.lua:3: Expected 1 to equal 2")
	-- Context lines with line-number gutter.
	test.includes(plain, '1 │ local test = require("lde-test")')
	test.includes(plain, '2 │ test.it("fails", function()')
	test.includes(plain, "3 │   test.equal(1, 2)")
	test.includes(plain, "4 │ end)")
	-- Caret pointing at the failing assertion call.
	test.truthy(plain:find("│%s+%^%^%^%^%^"))

	fs.rmdir(dir)
end)

test.it("runtime errors point the caret at the offending variable", function()
	local dir = makePackage("runtime", {
		["runtime.test.lua"] = 'local test = require("lde-test")\ntest.it("boom", function()\n  local x\n  return x.y\nend)\n',
	})

	local ok, out = ldecli({ "test" }, dir)
	test.falsy(ok)
	local plain = strip(out or "")

	test.includes(plain, "tests/runtime.test.lua:4: attempt to index local 'x' (a nil value)")
	test.includes(plain, "4 │   return x.y")
	test.truthy(plain:find("│%s+%^"))

	fs.rmdir(dir)
end)

test.it("test files that fail to load also print a snippet", function()
	local dir = makePackage("syntax", {
		["bad.test.lua"] = 'local test = require("lde-test")\ntest.it("oops", function(\nend)\n',
	})

	local ok, out = ldecli({ "test" }, dir)
	test.falsy(ok)
	local plain = strip(out or "")

	test.includes(plain, "FAIL bad.test.lua")
	test.includes(plain, "bad.test.lua:3:")
	test.includes(plain, '2 │ test.it("oops", function(')
	test.includes(plain, "3 │ end)")

	fs.rmdir(dir)
end)

test.it("snippets still work when the error path is truncated for long paths", function()
	local longName = "truncation-" .. string.rep("x", 60)
	local dir = makePackage(longName, {
		["fail.test.lua"] = 'local test = require("lde-test")\ntest.it("fails", function()\n  test.equal(1, 2)\nend)\n',
	})

	local ok, out = ldecli({ "test" }, dir)
	test.falsy(ok)
	local plain = strip(out or "")

	test.includes(plain, "tests/fail.test.lua:3: Expected 1 to equal 2")
	test.includes(plain, "3 │   test.equal(1, 2)")
	test.truthy(plain:find("│%s+%^%^%^%^%^"))

	fs.rmdir(dir)
end)
