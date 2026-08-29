local test = require("lde-test")

local fs   = require("fs")
local env  = require("env")
local path = require("path")

local lde = require("lde-core")
local fg  = require("lde-core.flamegraph")

local tmpBase = path.join(env.tmpdir(), "lde-profile-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

-- ── flamegraph.buildTree ──────────────────────────────────────────────────────

test.it("buildTree: single stack produces root with one child", function()
	local root = fg.buildTree({ ["a"] = 5 }, "root")
	test.equal(root.n, "root")
	test.equal(root.v, 5)
	test.equal(#root.c, 1)
	test.equal(root.c[1].n, "a")
	test.equal(root.c[1].v, 5)
end)

test.it("buildTree: root value is the sum of all stack counts", function()
	local root = fg.buildTree({ ["a"] = 3, ["b"] = 7, ["a;b"] = 2 }, "root")
	test.equal(root.v, 12)
end)

test.it("buildTree: stacks with a shared prefix merge into the same parent", function()
	-- Both stacks go through "outer" before diverging
	local root = fg.buildTree({ ["outer;left"] = 4, ["outer;right"] = 6 }, "root")
	test.equal(#root.c, 1)
	local outer = root.c[1]
	test.equal(outer.n, "outer")
	test.equal(outer.v, 10)
	test.equal(#outer.c, 2)
	-- children may be in any order
	local names = {}
	for _, c in ipairs(outer.c) do names[c.n] = c.v end
	test.equal(names["left"],  4)
	test.equal(names["right"], 6)
end)

test.it("buildTree: deep stack produces correctly nested children", function()
	local root = fg.buildTree({ ["a;b;c;d"] = 1 }, "root")
	local node = root.c[1] -- a
	test.equal(node.n, "a")
	node = node.c[1] -- b
	test.equal(node.n, "b")
	node = node.c[1] -- c
	test.equal(node.n, "c")
	node = node.c[1] -- d
	test.equal(node.n, "d")
	test.equal(#node.c, 0)
end)

test.it("buildTree: same frame appearing in multiple stacks accumulates count", function()
	local root = fg.buildTree({ ["outer;inner"] = 3, ["outer"] = 2 }, "root")
	local outer = root.c[1]
	test.equal(outer.n, "outer")
	test.equal(outer.v, 5) -- 3 + 2
	test.equal(#outer.c, 1)
	test.equal(outer.c[1].v, 3) -- only the deeper stack contributed
end)

test.it("buildTree: uses 'root' as default root name", function()
	local root = fg.buildTree({ ["x"] = 1 })
	test.equal(root.n, "root")
end)

-- ── flamegraph.write ──────────────────────────────────────────────────────────

test.it("write: returns error for empty stacks", function()
	local ok, err = fg.write({}, 0, 10, path.join(tmpBase, "empty.html"))
	test.falsy(ok)
	test.truthy(err) ---@cast err -nil
	test.includes(err, "no stack data")
end)

test.it("write: creates an HTML file for non-empty stacks", function()
	local outPath = path.join(tmpBase, "basic.html")
	local ok, err = fg.write({ ["fn_a;fn_b"] = 5 }, 5, 10, outPath, "test")
	test.truthy(ok)
	test.falsy(err)
	test.truthy(fs.exists(outPath))
end)

test.it("write: output contains no unsubstituted template placeholders", function()
	local outPath = path.join(tmpBase, "placeholders.html")
	fg.write({ ["fn_a"] = 3 }, 3, 10, outPath, "my profile")
	local html = fs.read(outPath) ---@cast html -nil
	test.falsy(html:find("__DATA__",   1, true))
	test.falsy(html:find("__TITLE__",  1, true))
	test.falsy(html:find("__MS__",     1, true))
end)

test.it("write: output is valid HTML with embedded JSON data", function()
	local outPath = path.join(tmpBase, "valid.html")
	fg.write({ ["outer;inner"] = 7 }, 7, 10, outPath)
	local html = fs.read(outPath) ---@cast html -nil
	test.truthy(html:find("<!DOCTYPE html>", 1, true))
	test.truthy(html:find("var D={",         1, true))
	test.truthy(html:find("var D=.*MS=10",   1, false)) -- MS substituted
end)

test.it("write: title appears in the HTML output", function()
	local outPath = path.join(tmpBase, "titled.html")
	fg.write({ ["x"] = 1 }, 1, 10, outPath, "My Cool Script")
	local html = fs.read(outPath) ---@cast html -nil
	test.truthy(html:find("My Cool Script", 1, true))
end)

test.it("write: JSON data contains the expected root node name", function()
	local outPath = path.join(tmpBase, "rootname.html")
	fg.write({ ["bench;inner"] = 4 }, 4, 10, outPath, "myscript")
	local html = fs.read(outPath) ---@cast html -nil
	-- root is named after the title; "bench" and "inner" should be child nodes
	test.truthy(html:find('"n":"myscript"', 1, true))
	test.truthy(html:find('"n":"bench"',    1, true))
	test.truthy(html:find('"n":"inner"',    1, true))
end)

test.it("write: handles percent signs in node names without corrupting output", function()
	-- A % in a function name or path must not break Lua gsub replacement strings
	local outPath = path.join(tmpBase, "percent.html")
	local ok = fg.write({ ["fn_50%_done"] = 2 }, 2, 10, outPath)
	test.truthy(ok)
	local html = fs.read(outPath) ---@cast html -nil
	test.truthy(html:find("fn_50", 1, true))
	test.falsy(html:find("__DATA__", 1, true))
end)

-- ── runtime: profile option ───────────────────────────────────────────────────

test.it("executeFile with profile=true succeeds and returns ok", function()
	local scriptPath = path.join(tmpBase, "prof.lua")
	fs.write(scriptPath, [[
		local s = 0
		for i = 1, 500000 do s = s + i end
		return s
	]])
	local ok, err = lde.runtime.executeFile(scriptPath, { profile = true })
	test.truthy(ok)
end)

test.it("executeString with profile=true succeeds", function()
	local ok, err = lde.runtime.executeString([[
		local s = 0
		for i = 1, 300000 do s = s + i end
	]], { profile = true })
	test.truthy(ok)
end)

-- ── runtime: flamegraph option ────────────────────────────────────────────────

test.it("executeFile with flamegraph path writes an HTML file", function()
	local scriptPath = path.join(tmpBase, "fg_script.lua")
	local outPath    = path.join(tmpBase, "fg_out.html")
	fs.write(scriptPath, [[
		local s = 0
		for i = 1, 1000000 do s = s + i end
		return s
	]])
	local ok, err = lde.runtime.executeFile(scriptPath, { flamegraph = outPath })
	test.truthy(ok)
	-- File may or may not exist if no samples were collected (fast machine / CI);
	-- if it does exist it must be valid HTML with no placeholders.
	if fs.exists(outPath) then
		local html = fs.read(outPath) ---@cast html -nil
		test.truthy(html:find("<!DOCTYPE html>", 1, true))
		test.falsy(html:find("__DATA__",  1, true))
		test.falsy(html:find("__MS__",    1, true))
		test.falsy(html:find("__TITLE__", 1, true))
	end
end)

test.it("executeFile with profile=true and flamegraph path both work together", function()
	local scriptPath = path.join(tmpBase, "both_script.lua")
	local outPath    = path.join(tmpBase, "both_out.html")
	fs.write(scriptPath, [[
		local s = 0
		for i = 1, 1000000 do s = s + i end
		return s
	]])
	local ok = lde.runtime.executeFile(scriptPath, {
		profile   = true,
		flamegraph = outPath,
	})
	test.truthy(ok)
end)

test.it("executeFile with profileJson writes decodable profile data", function()
	local scriptPath = path.join(tmpBase, "json_script.lua")
	local outPath    = path.join(tmpBase, "json_out.json")
	fs.write(scriptPath, [[
		local function work(n)
			local s = 0
			for i = 1, n do s = s + i end
			return s
		end
		for i = 1, 20 do work(1000000) end
	]])

	local ok = lde.runtime.executeFile(scriptPath, { profileJson = outPath })
	test.truthy(ok)
	test.truthy(fs.exists(outPath), "profile JSON not written")

	local json = require("json")
	local raw = fs.read(outPath) ---@cast raw -nil
	local data = json.decode(raw) ---@cast data table
	test.truthy(data, "profile JSON must decode")
	test.equal(data.version, 1)
	test.equal(data.intervalMs, 1)
	test.truthy(data.total > 0, "expected samples, got total=" .. tostring(data.total))
	test.equal(data.totalMs, data.total)
	test.truthy(type(data.vmstates) == "table" and next(data.vmstates) ~= nil)
	test.truthy(type(data.stacks) == "table" and next(data.stacks) ~= nil)
	local work
	for _, h in ipairs(data.hotspots) do
		if h.loc == "work" then work = h end
	end
	test.truthy(work, "expected a 'work' hotspot")
	test.truthy(work.count > 0)
end)

test.it("executeFile with flamegraph: no crash when script errors", function()
	local scriptPath = path.join(tmpBase, "fg_error.lua")
	local outPath    = path.join(tmpBase, "fg_error_out.html")
	fs.write(scriptPath, [[
		local s = 0
		for i = 1, 200000 do s = s + i end
		error("intentional error after work")
	]])
	local ok, err = lde.runtime.executeFile(scriptPath, { flamegraph = outPath })
	test.falsy(ok)      -- script errored
	test.truthy(err)    -- error message is propagated
	-- profiler must have been stopped cleanly (no crash, no hang)
end)

test.it("profiling stays silent while quiet, but still writes artifacts", function()
	-- The test runner sets lde.isQuiet, so executeFile's profile report and
	-- status lines must not leak into the suite's output ("Profile: no
	-- samples collected", "Flamegraph error: ...", ...). The requested
	-- artifacts must still be written.
	test.truthy(lde.isQuiet, "this suite must run with lde.isQuiet set")

	local scriptPath = path.join(tmpBase, "silent.lua")
	local htmlPath   = path.join(tmpBase, "silent_out.html")
	local jsonPath   = path.join(tmpBase, "silent_out.json")
	fs.write(scriptPath, [[
		local function work(n)
			local s = 0
			for i = 1, n do s = s + i end
			return s
		end
		for i = 1, 20 do work(1000000) end
	]])

	-- Capture everything the profiling paths print (printProfileReport uses
	-- io.write, ansi.printf uses print) while the call runs.
	local captured = {}
	local origPrint, origWrite = print, io.write
	print = function(...)
		captured[#captured + 1] = table.concat({ ... }, "\t")
	end
	io.write = function(...)
		captured[#captured + 1] = table.concat({ ... }, "")
	end

	local ok = lde.runtime.executeFile(scriptPath, {
		profile     = true,
		flamegraph  = htmlPath,
		profileJson = jsonPath,
	})
	test.truthy(ok, "executeFile with profiling must succeed")

	print, io.write = origPrint, origWrite

	local text = table.concat(captured, "\n")
	test.falsy(text:find("Profile", 1, true), "profile report must not print while quiet")
	test.falsy(text:find("Flamegraph", 1, true), "flamegraph status must not print while quiet")
	test.falsy(text:find("Profile JSON", 1, true), "profile JSON status must not print while quiet")
	-- Artifacts still written (may be absent on a machine too fast to sample,
	-- same tolerance as the dedicated flamegraph test).
	test.truthy(fs.exists(jsonPath), "profile JSON must still be written")
	if fs.exists(htmlPath) then
		local html = fs.read(htmlPath) ---@cast html -nil
		test.truthy(html:find("<!DOCTYPE html>", 1, true))
	end
end)
