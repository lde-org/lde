local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")

local lde = require("lde-core")
local timings = require("lde-core.util.timings")

local tmpBase = path.join(env.tmpdir(), "lde-timings-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

-- Blocking sleep for building deterministic overlap in unit timing tests.
local ffi = require("ffi")
if jit.os == "Windows" then
	pcall(ffi.cdef, "void Sleep(unsigned long dwMilliseconds);")
else
	pcall(ffi.cdef, "int usleep(unsigned int usec);")
end

---@param ms number
local function sleepMs(ms)
	if jit.os == "Windows" then
		ffi.C.Sleep(ms)
	else
		ffi.C.usleep(ms * 1000)
	end
end

-- ── lifecycle ────────────────────────────────────────────────────────────────

test.it("start returns nil while inactive", function()
	timings.reset()
	local handle = timings.start("nope", "build")
	test.falsy(handle)
end)

test.it("begin activates collection and start/finish record units", function()
	timings.begin({ command = "test", package = "pkg" })
	test.truthy(timings.active())

	local a = timings.start("alpha", "build")
	test.truthy(a) ---@cast a -nil
	sleepMs(5)
	timings.finish(a)

	local data = timings.data()
	test.equal(data.command, "test")
	test.equal(data.package, "pkg")
	test.equal(data.summary.units, 1)
	test.equal(data.units[1].name, "alpha")
	test.equal(data.units[1].kind, "build")
	test.truthy(data.units[1].duration >= 0.004)
	test.truthy(data.units[1].start < 0.01, "first unit starts at t≈0")
	test.equal(data.maxParallelism, 1)
end)

test.it("begin resets prior collections", function()
	timings.begin({})
	local a = timings.start("one", "build")
	timings.finish(a)
	timings.begin({})
	test.equal(timings.data().summary.units, 0)
end)

test.it("finish is idempotent and start is a no-op when inactive", function()
	timings.begin({})
	local a = timings.start("x", "build")
	timings.finish(a)
	local end1 = timings.data().units[1]["end"]
	sleepMs(5)
	timings.finish(a)
	test.equal(timings.data().units[1]["end"], end1, "second finish must not move the end time")

	timings.finish(nil) -- must not raise
end)

test.it("reset stops collection and drops units", function()
	timings.begin({})
	local a = timings.start("x", "build")
	timings.finish(a)
	timings.reset()
	test.falsy(timings.active())
	test.equal(timings.data().summary.units, 0)
end)

-- ── parallelism ──────────────────────────────────────────────────────────────

test.it("overlapping units report maxParallelism 2", function()
	timings.begin({})
	local a = timings.start("a", "build")
	sleepMs(20)
	local b = timings.start("b", "build")
	sleepMs(20)
	timings.finish(b)
	sleepMs(20)
	timings.finish(a)
	test.equal(timings.data().maxParallelism, 2)
	test.equal(timings.data().summary.units, 2)
end)

test.it("sequential units report maxParallelism 1", function()
	timings.begin({})
	local a = timings.start("a", "build")
	sleepMs(10)
	timings.finish(a)
	local b = timings.start("b", "build")
	sleepMs(10)
	timings.finish(b)
	test.equal(timings.data().maxParallelism, 1)
end)

test.it("data aggregates time by kind", function()
	timings.begin({})
	local a = timings.start("a", "build")
	sleepMs(10)
	timings.finish(a)
	local b = timings.start("b", "download")
	sleepMs(10)
	timings.finish(b)

	local byKind = timings.data().summary.byKind
	test.equal(byKind.build.count, 1)
	test.truthy(byKind.build.time >= 0.009)
	test.equal(byKind.download.count, 1)
	test.equal(#timings.data().units, 2)
end)

-- ── JSON output ──────────────────────────────────────────────────────────────

test.it("writeJSON writes decodable JSON with the collected units", function()
	timings.begin({ command = "sync", package = "pkg" })
	local a = timings.start("build alpha", "build")
	sleepMs(5)
	timings.finish(a)

	local outPath = path.join(tmpBase, "timings.json")
	local ok, err = timings.writeJSON(outPath)
	test.truthy(ok, "writeJSON must succeed") ---@cast err -nil
	test.falsy(err)
	test.truthy(fs.exists(outPath))

	local decoded = json.decode(fs.read(outPath) --[[@as string]]) ---@cast decoded table
	test.equal(decoded.version, 1)
	test.equal(decoded.command, "sync")
	test.equal(decoded.package, "pkg")
	test.equal(decoded.summary.units, 1)
	test.equal(decoded.units[1].name, "build alpha")
	test.equal(type(decoded.units[1].duration), "number")
	test.truthy(decoded.totalTime > 0)
end)

-- ── HTML output ──────────────────────────────────────────────────────────────

test.it("writeHTML produces a self-contained report", function()
	timings.begin({ command = "compile", package = "pkg" })
	local a = timings.start("sea compile", "compile")
	sleepMs(5)
	timings.finish(a)

	local outPath = path.join(tmpBase, "timings.html")
	local ok, err = timings.writeHTML(outPath)
	test.truthy(ok, "writeHTML must succeed") ---@cast err -nil
	test.falsy(err)
	test.truthy(fs.exists(outPath))

	local html = fs.read(outPath) ---@cast html -nil
	test.truthy(html:find("<!DOCTYPE html>", 1, true))
	test.truthy(html:find("lde timings", 1, true))
	test.truthy(html:find("sea compile", 1, true))
	test.truthy(html:find("Max parallelism", 1, true))
	test.falsy(html:find("__TITLE__", 1, true), "no unsubstituted placeholders")
	test.falsy(html:find("__DATA__", 1, true))
end)

test.it("writeHTML escapes unit names", function()
	timings.begin({})
	local a = timings.start("<script>alert(1)</script>", "build")
	sleepMs(2)
	timings.finish(a)

	local outPath = path.join(tmpBase, "escape.html")
	timings.writeHTML(outPath)
	local html = fs.read(outPath) ---@cast html -nil
	test.truthy(html:find("&lt;script&gt;", 1, true))
	test.falsy(html:find("<script>alert", 1, true))
end)

test.it("write returns an error when nothing was collected", function()
	timings.reset()
	local outPath = path.join(tmpBase, "empty.html")
	local ok, err = timings.writeHTML(outPath)
	test.falsy(ok)
	test.truthy(err) ---@cast err -nil
	test.includes(err, "no timings collected")
end)
