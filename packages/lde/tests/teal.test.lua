local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")

local ldecli = require("tests.lib.ldecli")

test.it("runs Teal (.tl) packages out of the box", function()
	local tmpDir = path.join(env.tmpdir(), "lde-teal-run-test")
	fs.rmdir(tmpDir)
	fs.mkdir(tmpDir)
	fs.mkdir(path.join(tmpDir, "src"))
	fs.write(path.join(tmpDir, "lde.json"), json.encode({ name = "tealfix", version = "0.1.0" }))
	fs.write(path.join(tmpDir, "src", "init.tl"), [[
		local greet = require("tealfix.greet")
		local n: integer = 40
		print(greet("tl") .. " " .. tostring(n + 2))
	]])
	fs.write(path.join(tmpDir, "src", "greet.tl"), [[
		local function greet(name: string): string
			return "hello " .. name
		end
		return greet
	]])

	local ok, out = ldecli({ "run" }, tmpDir)
	test.truthy(ok)
	test.includes(out or "", "hello tl 42")

	-- The build compiled Teal to Lua in target/, but kept the .tl sources
	-- next to their .lua output so `tl check` can resolve modules via target/.
	local targetDir = path.join(tmpDir, "target", "tealfix")
	test.truthy(fs.exists(path.join(targetDir, "init.lua")))
	test.truthy(fs.exists(path.join(targetDir, "greet.lua")))
	test.truthy(fs.exists(path.join(targetDir, "init.tl")))
	test.truthy(fs.exists(path.join(targetDir, "greet.tl")))

	-- Bundles only carry the compiled Lua; .tl sources never leak in.
	local ok2, bundleErr = ldecli({ "bundle" }, tmpDir)
	if not ok2 then error("bundle failed: " .. tostring(bundleErr), 2) end
	local bundle = fs.read(path.join(tmpDir, "tealfix.lua"))
	if not bundle then error("bundle produced no output", 2) end
	test.falsy(bundle:find(".tl", 1, true))

	fs.rmdir(tmpDir)
end)

test.it("runs a bare .tl file outside a package", function()
	local tmpDir = path.join(env.tmpdir(), "lde-teal-bare-test")
	fs.rmdir(tmpDir)
	fs.mkdir(tmpDir)
	fs.write(path.join(tmpDir, "hello.tl"), [[
		local s: string = "bare tl"
		print(s)
	]])

	local script = path.join(tmpDir, "hello.tl") --[[@as string]]
	local ok, out = ldecli({ script })
	test.truthy(ok)
	test.includes(out or "", "bare tl")

	fs.rmdir(tmpDir)
end)

test.it("reports Teal syntax errors with file:line:col", function()
	local tmpDir = path.join(env.tmpdir(), "lde-teal-syntax-test")
	fs.rmdir(tmpDir)
	fs.mkdir(tmpDir)
	fs.mkdir(path.join(tmpDir, "src"))
	-- A plain package, so the child runs in a package context and prints the
	-- compile error to stdout regardless of where the suite was launched from.
	fs.write(path.join(tmpDir, "lde.json"), json.encode({ name = "teal-bad", version = "0.1.0" }))
	fs.write(path.join(tmpDir, "src", "init.lua"), "return true")
	fs.write(path.join(tmpDir, "bad.tl"), "local = 3\n")

	local script = path.join(tmpDir, "bad.tl") --[[@as string]]
	local ok, out = ldecli({ script }, tmpDir)
	test.falsy(ok)
	if not (out and out:find("bad.tl:1:7", 1, true)) then
		error("Expected compile error at bad.tl:1:7, got: " .. tostring(out), 2)
	end

	fs.rmdir(tmpDir)
end)

test.it("runs Teal (.tl) test files via lde test", function()
	local tmpDir = path.join(env.tmpdir(), "lde-teal-test-files")
	fs.rmdir(tmpDir)
	fs.mkdir(tmpDir)
	fs.mkdir(path.join(tmpDir, "src"))
	fs.mkdir(path.join(tmpDir, "tests"))
	fs.write(path.join(tmpDir, "lde.json"), json.encode({ name = "tealtests", version = "0.1.0" }))
	fs.write(path.join(tmpDir, "src", "init.lua"), "return true")
	fs.write(path.join(tmpDir, "tests", "a.test.tl"), [[
		local t = require("lde-test")
		t.it("tl test passes", function()
			t.equal(40 + 2, 42)
		end)
	]])

	local ok, out = ldecli({ "test" }, tmpDir)
	test.truthy(ok)
	test.includes(out or "", "tl test passes")

	-- Compiled to Lua under target/tests; the .tl source is kept next to it
	-- (like src/ builds) but the runner only executes the compiled .lua.
	local testsTarget = path.join(tmpDir, "target", "tests")
	test.truthy(fs.exists(path.join(testsTarget, "a.test.lua")))
	test.truthy(fs.exists(path.join(testsTarget, "a.test.tl")))
	test.falsy(fs.islink(testsTarget))
	test.falsy(fs.exists(path.join(testsTarget, ".lde-tests-stamp")))

	-- A .tl filter runs the compiled file.
	local ok2, out2 = ldecli({ "test", "--", path.join(tmpDir, "tests", "a.test.tl") }, tmpDir)
	test.truthy(ok2)
	test.includes(out2 or "", "tl test passes")

	fs.rmdir(tmpDir)
end)
