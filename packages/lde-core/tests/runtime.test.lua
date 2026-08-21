-- In-process tests for the runtime module: the --lua CLI interpreter shim
-- (executeLuaCLI), the profile report formatting, and compiled-file reading.
-- The CLI-level equivalents are covered through child processes in
-- packages/lde/tests; these drive the code directly so the coverage instrument
-- sees it.
local test = require("lde-test")

local lde = require("lde-core")

local fs = require("fs")
local env = require("env")
local path = require("path")

local tmpBase = path.join(env.tmpdir(), "lde-runtime-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

--
-- executeLuaCLI (the --lua interpreter shim)
--

test.it("executeLuaCLI runs -e chunks and returns their value", function()
	local ok, r = lde.runtime.executeLuaCLI({ "-e", "return 40 + 2" })
	test.truthy(ok)
	test.equal(r, 42)
end)

test.it("executeLuaCLI chains multiple -e chunks in one state", function()
	local ok, r = lde.runtime.executeLuaCLI({ "-e", "x = 5", "-e", "return x * 2" })
	test.truthy(ok)
	test.equal(r, 10)
end)

test.it("executeLuaCLI runs a script with its args and arg[0] = script path", function()
	local script = path.join(tmpBase, "args.lua")
	fs.write(script, 'return arg[0] .. "|" .. arg[1] .. "|" .. arg[2]')

	local ok, r = lde.runtime.executeLuaCLI({ script, "a", "b" })
	test.truthy(ok)
	test.equal(r, script .. "|a|b")
end)

test.it("executeLuaCLI -e chunks run before the script in the same state", function()
	local script = path.join(tmpBase, "chained.lua")
	fs.write(script, "return marker")

	local ok, r = lde.runtime.executeLuaCLI({ "-e", "marker = 'from-chunk'", script })
	test.truthy(ok)
	test.equal(r, "from-chunk")
end)

test.it("executeLuaCLI rebuilds arg for the script after -e chunks", function()
	local script = path.join(tmpBase, "eargs.lua")
	fs.write(script, 'return arg[0] .. "|" .. arg[1]')

	local ok, r = lde.runtime.executeLuaCLI({ "-e", "x = 1", script, "v" })
	test.truthy(ok)
	test.equal(r, script .. "|v")
end)

test.it("executeLuaCLI surfaces script errors", function()
	local script = path.join(tmpBase, "boom.lua")
	fs.write(script, 'error("kaboom")')

	local ok, r = lde.runtime.executeLuaCLI({ script })
	test.falsy(ok)
	test.includes(tostring(r), "kaboom")
end)

test.it("executeLuaCLI rejects a missing -e argument", function()
	local ok, r = lde.runtime.executeLuaCLI({ "-e" })
	test.falsy(ok)
	test.includes(tostring(r), "no code given")
end)

test.it("executeLuaCLI rejects an empty command line", function()
	local ok, r = lde.runtime.executeLuaCLI({})
	test.falsy(ok)
	test.includes(tostring(r), "no script or -e chunk")
end)

--
-- Profile report formatting (captured io.write)
--

test.it("profile report prints VM state and hotspot sections", function()
	local script = path.join(tmpBase, "prof.lua")
	fs.write(script, [[
		local function work(n)
			local s = 0
			for i = 1, n do s = s + i end
			return s
		end
		for i = 1, 20 do work(1000000) end
	]])

	local oldIsVerbose, oldWrite = lde.isVerbose, io.write
	local buf = {}
	io.write = function(...)
		local parts = { ... }
		for i, p in ipairs(parts) do buf[#buf + 1] = tostring(p) end
	end
	lde.isVerbose = true
	local ok = lde.runtime.executeFile(script, { profile = true })
	io.write = oldWrite
	lde.isVerbose = oldIsVerbose

	test.truthy(ok)
	local out = table.concat(buf)
	test.includes(out, "Profile")
	test.includes(out, "Hotspots")
	test.includes(out, "work")
	-- The VM state breakdown labels are present (interpreted or JIT compiled).
	test.truthy(out:find("Interpreted", 1, true) or out:find("JIT compiled", 1, true))
end)

--
-- readCompiledFile: Teal / Moonscript sources compile to Lua
--

test.it("readCompiledFile compiles a Teal entry point", function()
	local tl = path.join(tmpBase, "entry.tl")
	fs.write(tl, "local n: integer = 40\nreturn tostring(n + 2)\n")
	local source, err = lde.runtime.readCompiledFile(tl)
	test.truthy(source, err or "teal compile failed") ---@cast source -nil
	test.truthy(source:find("return", 1, true))
	test.truthy(source:find("tostring", 1, true))
end)

test.it("readCompiledFile compiles a Moonscript entry point", function()
	local moon = path.join(tmpBase, "entry.moon")
	fs.write(moon, "print \"moon\"\n")
	local source, err = lde.runtime.readCompiledFile(moon)
	test.truthy(source, err or "moonscript compile failed") ---@cast source -nil
	test.truthy(source:find("print", 1, true))
end)
