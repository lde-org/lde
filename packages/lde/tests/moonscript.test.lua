local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")
local util = require("util")

local ldecli = require("tests.lib.ldecli")

test.it("runs Moonscript (.moon) packages out of the box", function()
	local tmpDir = path.join(env.tmpdir(), "lde-moon-run-test")
	fs.rmdir(tmpDir)
	fs.mkdir(tmpDir)
	fs.mkdir(path.join(tmpDir, "src"))
	fs.write(path.join(tmpDir, "lde.json"), json.encode({ name = "moonfix", version = "0.1.0" }))
	-- Moonscript is indentation-sensitive, so the fixture code must sit at
	-- column 0 in the written files (dedent strips the long-string indent).
	fs.write(path.join(tmpDir, "src", "init.moon"), util.dedent([[
		greet = require("moonfix.greet")
		n = 40
		print(greet("moon") .. " " .. tostring(n + 2))
	]]))
	fs.write(path.join(tmpDir, "src", "greet.moon"), util.dedent([[
		greet = (name) -> "hello " .. name
		return greet
	]]))

	local ok, out = ldecli({ "run" }, tmpDir)
	test.truthy(ok)
	test.includes(out or "", "hello moon 42")

	-- The build compiled Moonscript to Lua in target/; no raw .moon survives.
	local targetDir = path.join(tmpDir, "target", "moonfix")
	test.truthy(fs.exists(path.join(targetDir, "init.lua")))
	test.truthy(fs.exists(path.join(targetDir, "greet.lua")))
	test.falsy(fs.exists(path.join(targetDir, "init.moon")))

	fs.rmdir(tmpDir)
end)

test.it("runs a bare .moon file outside a package", function()
	local tmpDir = path.join(env.tmpdir(), "lde-moon-bare-test")
	fs.rmdir(tmpDir)
	fs.mkdir(tmpDir)
	fs.write(path.join(tmpDir, "hello.moon"), util.dedent([[
		s = "bare moon"
		print s
	]]))

	local script = path.join(tmpDir, "hello.moon") --[[@as string]]
	local ok, out = ldecli({ script })
	test.truthy(ok)
	test.includes(out or "", "bare moon")

	fs.rmdir(tmpDir)
end)
