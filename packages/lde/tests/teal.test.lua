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

	-- The build compiled Teal to Lua in target/; no raw .tl survives.
	local targetDir = path.join(tmpDir, "target", "tealfix")
	test.truthy(fs.exists(path.join(targetDir, "init.lua")))
	test.truthy(fs.exists(path.join(targetDir, "greet.lua")))
	test.falsy(fs.exists(path.join(targetDir, "init.tl")))

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
