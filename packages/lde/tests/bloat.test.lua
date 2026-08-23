-- Tests for `lde bloat`: builds the project and reports what makes up the
-- compiled bundle — a proportional bar, per-dependency/per-file sizes as a
-- percentage of the total, and an optional JSON report.
local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")

local cli = require("tests.lib.ldecli")

local tmpBase = path.join(env.tmpdir(), "lde-bloat-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

---Strip ANSI escape sequences so output matches work with or without colors.
---@param s string
---@return string
local function plain(s)
	return ((s or ""):gsub("\27%[[0-9;]*m", ""))
end

---@param name string
---@param deps table?
---@param extra table?
---@return string dir
local function makeProject(name, deps, extra)
	local dir = path.join(tmpBase, name)
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), 'return "' .. name .. '"')
	local config = {
		name = name,
		version = "0.1.0",
		dependencies = deps or {}
	}
	if extra then
		for k, v in pairs(extra) do config[k] = v end
	end
	fs.write(path.join(dir, "lde.json"), json.encode(config))
	return dir
end

test.it("lde bloat renders the header, bar, legend and sized dependency tree", function()
	local bigDir = makeProject("bloat-big", nil, { name = "bloat-big" })
	fs.write(path.join(bigDir, "src", "a.lua"), 'return "a"')
	fs.write(path.join(bigDir, "src", "b.lua"), 'return "b"')
	fs.mkdir(path.join(bigDir, "src", "sub"))
	fs.write(path.join(bigDir, "src", "sub", "x.lua"), 'return "x"')
	makeProject("bloat-small", nil, { name = "bloat-small" })
	local dir = makeProject("bloat-app", {
		["bloat-big"] = { path = "../bloat-big" },
		["bloat-small"] = { path = "../bloat-small" }
	})

	local ok, out = cli({ "bloat" }, dir)
	test.truthy(ok, "lde bloat failed: " .. tostring(out))
	local text = plain(out or "")
	test.includes(text, "Bloat report: bloat-app")
	test.includes(text, "Lua: ")
	test.includes(text, "Native: ")
	test.includes(text, "Total: ")
	test.includes(text, "(bytecode)")
	-- Proportional bar (no brackets) and its vertical legend.
	test.includes(text, "█")
	test.includes(text, "██ bloat-big")
	test.includes(text, "██ bloat-small")
	-- Sized tree with per-file breakdown, names relative to their dependency.
	test.includes(text, "sub.x")
	test.includes(text, "init.lua")
	test.includes(text, "your code")
	-- The dependency prefix must not repeat on its own files.
	test.falsy(text:find("bloat%-big%.sub%.x", 1, true))
	test.falsy(text:find("bloat%-big%.a", 1, true))
	-- The bigger dependency must sort above the smaller one.
	local bigPos = text:find("bloat%-big")
	local smallPos = text:find("bloat%-small")
	test.truthy(bigPos and smallPos and bigPos < smallPos, "deps must sort by size descending")
end)

test.it("lde bloat reports the exact embedded bytecode size", function()
	makeProject("bloat-tiny", nil, { name = "bloat-tiny" })
	local dir = makeProject("bloat-size-app", {
		["bloat-tiny"] = { path = "../bloat-tiny" }
	})

	-- bundlePackage compiles each module with the module name as its chunkname;
	-- the same bytecode must appear verbatim in the report.
	local fn = assert(loadstring('return "bloat-tiny"', "bloat-tiny"))
	local expected = string.dump(fn)
	local ok, out = cli({ "bloat" }, dir)
	test.truthy(ok, "lde bloat failed: " .. tostring(out))
	test.includes(plain(out or ""), #expected .. " B")
end)

test.it("lde bloat percentages sum to 100% of the embedded bundle", function()
	makeProject("bloat-sum-a", nil, { name = "bloat-sum-a" })
	makeProject("bloat-sum-b", nil, { name = "bloat-sum-b" })
	local dir = makeProject("bloat-sum-app", {
		["bloat-sum-a"] = { path = "../bloat-sum-a" },
		["bloat-sum-b"] = { path = "../bloat-sum-b" }
	})

	local ok, out = cli({ "bloat" }, dir)
	test.truthy(ok, "lde bloat failed: " .. tostring(out))
	-- Dependency rows are `name  size (pct)` (root rows carry a trailing
	-- `(your code)`). Header/analysis rows contain ":", legend rows start with
	-- a swatch, and file rows start with the tree char — none of them match.
	local sum = 0
	for line in (plain(out or "")):gmatch("[^\r\n]+") do
		if not line:find(":", 1, true) then
			local pct = line:match("^[%w%-_.]+%s+.*%s+%((%d+%.?%d*)%%%)")
			if pct then sum = sum + tonumber(pct) end
		end
	end
	test.truthy(math.abs(sum - 100) < 2, "dependency percentages must sum to ~100, got " .. sum)
end)

test.it("lde bloat --binary reports the LuaJIT runtime share", function()
	local dir = makeProject("bloat-bin", nil, { name = "bloat-bin" })
	local binPath = path.join(dir, "bloat-bin")
	if jit.os == "Windows" then binPath = binPath .. ".exe" end
	-- A fake compiled binary at the default `lde compile` output path.
	fs.write(binPath, string.rep("x", 10000))

	local ok, out = cli({ "bloat", "--binary" }, dir)
	test.truthy(ok, "lde bloat --binary failed: " .. tostring(out))
	local text = plain(out or "")
	test.includes(text, "binary: " .. binPath)
	test.includes(text, "9.8 KB") -- the 10000-byte binary
	test.includes(text, "LuaJIT runtime + C glue")
	test.includes(text, "of binary")
end)

test.it("lde bloat --binary <path> uses the given binary", function()
	local dir = makeProject("bloat-bin-explicit")
	local binPath = path.join(dir, "custom.out")
	fs.write(binPath, string.rep("y", 2048))

	local ok, out = cli({ "bloat", "--binary", binPath }, dir)
	test.truthy(ok, "lde bloat --binary <path> failed: " .. tostring(out))
	local text = plain(out or "")
	test.includes(text, "binary: " .. binPath)
	test.includes(text, "2.0 KB")
	test.includes(text, "LuaJIT runtime + C glue")
end)

test.it("lde bloat --binary reports a missing binary", function()
	local dir = makeProject("bloat-missing")
	local ok, out = cli({ "bloat", "--binary", path.join(dir, "nope") }, dir)
	test.falsy(ok, "missing binary must fail")
	test.includes(plain(out or ""), "Binary not found")
end)

test.it("lde bloat --json prints a JSON report to stdout", function()
	makeProject("bloat-json-dep", nil, { name = "bloat-json-dep" })
	local dir = makeProject("bloat-json-app", {
		["bloat-json-dep"] = { path = "../bloat-json-dep" }
	})

	local ok, out = cli({ "bloat", "--json" }, dir)
	test.truthy(ok, "lde bloat --json failed: " .. tostring(out))
	local data = json.decode(out or "")
	test.truthy(data, "expected JSON output")
	---@cast data table<string, any>
	test.equal(data.name, "bloat-json-app")
	test.truthy(data.totalBytes > 0, "expected a positive total")
	test.truthy(data.luaFiles >= 2, "expected the app and dep modules")
	test.equal(data.nativeFiles, 0)
	local dep
	for _, e in ipairs(data.entries) do
		if e.name == "bloat-json-dep" then dep = e end
	end
	test.truthy(dep, "expected a bloat-json-dep entry")
	test.truthy(dep.bytes > 0)
	test.equal(dep.isRoot, false)
	test.equal(#dep.files, 1)
	test.equal(dep.files[1].kind, "lua")
	test.truthy(dep.files[1].bytes > 0)
end)

test.it("lde bloat --json <path> writes the report to a file", function()
	local dir = makeProject("bloat-json-file")
	local reportPath = path.join(dir, "bloat.json")

	local ok, out = cli({ "bloat", "--json", reportPath }, dir)
	test.truthy(ok, "lde bloat --json <path> failed: " .. tostring(out))
	test.truthy(fs.exists(reportPath), "report file not written")
	local data = json.decode(fs.read(reportPath) or "")
	test.truthy(data, "expected JSON in the file")
	---@cast data table<string, any>
	test.equal(data.name, "bloat-json-file")
	test.truthy(data.totalBytes > 0)
end)
