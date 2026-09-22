local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")
local process = require("process")
local ffi = require("ffi")

-- Cross-platform sleep used to poll the child's log file.
local sleep
if jit.os == "Windows" then
	pcall(ffi.cdef, "void Sleep(unsigned long dwMilliseconds);")
	sleep = function(ms) ffi.C.Sleep(ms) end
else
	pcall(ffi.cdef, "int usleep(unsigned int usec);")
	sleep = function(ms) ffi.C.usleep(ms * 1000) end
end

local tmpBase = path.join(env.tmpdir(), "lde-hot-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

local ldePath = assert(env.execPath())

-- CI forces colors on (GITHUB_ACTIONS/GITLAB_CI), so the session's output is
-- stripped before it is matched on.
---@param s string?
local function plain(s)
	return ((s or ""):gsub("\27%[[0-9;]*m", ""))
end

-- Poll the log file until it contains needle, or fail after timeoutMs.
---@param logPath string
---@param needle string
---@param timeoutMs number
local function waitForLog(logPath, needle, timeoutMs)
	local deadline = os.time() + timeoutMs / 1000
	while os.time() < deadline do
		local content = fs.read(logPath)
		if content and content:find(needle, 1, true) then return true end
		sleep(50)
	end
	return false
end

-- Poll the file until it contains at least `count` occurrences of `needle`.
---@param logPath string
---@param needle string
---@param count number
---@param timeoutMs number
local function waitForCount(logPath, needle, count, timeoutMs)
	local deadline = os.time() + timeoutMs / 1000
	while os.time() < deadline do
		local content = fs.read(logPath) or ""
		local _, n = content:gsub(needle, "")
		if n >= count then return true end
		sleep(50)
	end
	return false
end

-- Spawn the lde binary for a --hot/--watch session, run fn, then always kill
-- the child (even when fn errors, so a failed test can't leak a watcher).
-- The child's stdout/stderr are discarded by default: the tests observe the
-- session through log files the app writes, and the watcher's "Watching..." /
-- "Reloaded:" chatter would otherwise pollute the test runner's output.
--
-- With `capture`, they are piped and returned instead (stdout ++ stderr), read
-- after the child is killed. A killed process never flushes its stdout buffer,
-- so what comes back is exactly what the session flushed while it ran — which
-- is the point: it is how the driver's own reload chatter is observable when
-- the app owns its loop and never hands control back.
---@param args string[]
---@param cwd string
---@param fn fun(child: process.Child)
---@param capture boolean?
local function withChild(args, cwd, fn, capture)
	local child, err = process.spawn(ldePath, args, {
		cwd = cwd,
		stdout = capture and "pipe" or "null",
		stderr = capture and "pipe" or "null",
	})
	if not child then error("spawn failed: " .. tostring(err), 2) end ---@cast child process.Child
	local ok, perr = pcall(fn, child)
	-- Force-killed in capture mode: SIGKILL guarantees the pipes reach EOF
	-- (and so that wait() returns) no matter what the child is doing.
	child:kill(capture)
	local output
	if capture then
		local _, stdout, stderr = child:wait()
		output = (stdout or "") .. (stderr or "")
	end
	sleep(150)
	if not ok then error(perr, 2) end
	return output
end

---@param name string
---@return string dir
local function makePackage(name)
	local dir = path.join(tmpBase, name)
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "lde.json"), json.encode({ name = name, version = "0.1.0" }))
	return dir
end

-- Entry that logs "<version> runs=<n>" (n = _G.runs, which survives reloads
-- in --hot mode but resets in --watch mode) to the log file given as arg[1].
---@param modname string
---@return string
local function makeEntry(modname)
	return string.format([[
local util = require("%s")
_G.runs = (_G.runs or 0) + 1
local f = assert(io.open(arg[1], "a"))
f:write("run " .. util .. " runs=" .. _G.runs .. "\n")
f:close()
]], modname)
end

test.it("lde run --hot reloads changed modules in-place", function()
	local dir = makePackage("pkg-hot")
	fs.write(path.join(dir, "src", "utilmod.lua"), 'return "v1"')
	fs.write(path.join(dir, "src", "init.lua"), makeEntry("pkg-hot.utilmod"))

	local logFile = path.join(tmpBase, "pkg-hot.log")
	fs.write(logFile, "")

	withChild({ "run", "--hot", "--", logFile }, dir, function()
		test.truthy(waitForLog(logFile, "run v1 runs=1", 15000), "initial run missing from log")

		fs.write(path.join(dir, "src", "utilmod.lua"), 'return "v2"')

		-- The counter must be 2: --hot keeps the state alive and only drops the
		-- changed module from package.loaded (a --watch restart would reset it).
		test.truthy(waitForLog(logFile, "run v2 runs=2", 15000), "hot reload did not pick up v2 in-place")
	end)
end)

test.it("lde run --hot keeps the JIT on and reloads a loop that polls", function()
	local dir = makePackage("pkg-hot-poll")
	fs.write(path.join(dir, "src", "utilmod.lua"), 'return "v1"')
	-- A program that never returns: it can only be reloaded because it asks.
	fs.write(path.join(dir, "src", "init.lua"), [[
local util = require("pkg-hot-poll.utilmod")
_G.runs = (_G.runs or 0) + 1

local f = assert(io.open(arg[1], "a"))
f:write("run " .. util .. " runs=" .. _G.runs ..
	" jit=" .. tostring(jit.status()) .. " hook=" .. tostring(debug.gethook()) .. "\n")
f:close()

while true do
	package.hot.poll()
end
]])

	local logFile = path.join(tmpBase, "pkg-hot-poll.log")
	fs.write(logFile, "")

	withChild({ "run", "--hot", "--", logFile }, dir, function()
		test.truthy(waitForLog(logFile, "run v1 runs=1 jit=true hook=nil", 15000),
			"--hot must run without a debug hook and with the JIT on: " ..
				tostring(fs.read(logFile)))

		fs.write(path.join(dir, "src", "utilmod.lua"), 'return "v2"')

		test.truthy(waitForLog(logFile, "run v2 runs=2", 15000),
			"package.hot.poll() did not trigger a reload")
	end)
end)

test.it("lde run --hot prints a timed summary for every reload", function()
	local dir = makePackage("pkg-hot-banner")
	fs.write(path.join(dir, "src", "utilmod.lua"), 'return "v1"')

	-- A loop that polls owns the program: it never returns to the driver, so a
	-- reload summary left in the stdout buffer would sit there until the next
	-- reload interrupted the run — or die with the process. The child's stdout
	-- is captured and read after it is killed, so the summary has to have been
	-- flushed when it was printed.
	---@param tag string
	local function makePollEntry(tag)
		return string.format([[
local util = require("pkg-hot-banner.utilmod")
_G.runs = (_G.runs or 0) + 1
local f = assert(io.open(arg[1], "a"))
f:write("%s " .. util .. " runs=" .. _G.runs .. "\n")
f:close()

while true do
	package.hot.poll()
end
]], tag)
	end

	fs.write(path.join(dir, "src", "init.lua"), makePollEntry("run"))

	local logFile = path.join(tmpBase, "pkg-hot-banner.log")
	fs.write(logFile, "")

	local output = plain(withChild({ "run", "--hot", "--", logFile }, dir, function()
		test.truthy(waitForLog(logFile, "run v1 runs=1", 15000), "initial run missing from log")

		fs.write(path.join(dir, "src", "utilmod.lua"), 'return "version-2"')

		test.truthy(waitForLog(logFile, "run version-2 runs=2", 15000),
			"hot reload did not pick up the changed module")

		-- Only the entry point changes: no module is patched, so the summary
		-- reports the package name (the entry chunk has no require() path to be
		-- named by). This is the session's last reload, so nothing later can
		-- flush a banner that was left sitting in the buffer.
		fs.write(path.join(dir, "src", "init.lua"), makePollEntry("entry-2"))

		test.truthy(waitForLog(logFile, "entry-2 version-2 runs=3", 15000),
			"hot reload did not re-run the changed entry point")
	end, true))

	test.includes(output, "Reloaded: pkg-hot-banner.utilmod",
		"the reload summary must name the patched module: " .. output)
	-- "Reloaded: pkg-hot-banner (" cannot match the module line above, which
	-- carries the require() path and so reads "pkg-hot-banner.utilmod".
	test.truthy(output:find("Reloaded: pkg-hot-banner (", 1, true),
		"a reload that only re-runs the entry point must be reported under the package name: " .. output)
	local elapsed = output:match("Reloaded: pkg%-hot%-banner %(([^%)]+)%)")
	test.truthy(elapsed and (elapsed:find("µs", 1, true) or elapsed:find("ms", 1, true) or elapsed:find("s", 1, true)),
		"the reload summary must report how long the reload took, with a unit, got: " .. tostring(elapsed))
end)

test.it("lde run --hot rebuilds the state to recover from a run error", function()
	local dir = makePackage("pkg-hot-error")
	-- Declares an FFI type at load time. LuaJIT cannot un-declare a type, so
	-- re-running this module inside a state that already declared it fails: the
	-- only way back to a clean slate is a new state.
	fs.write(path.join(dir, "src", "native.lua"), [==[
local ffi = require("ffi")
ffi.cdef[[ typedef struct { int marker; } pkg_hot_error_probe; ]]
return "native-v1"
]==])

	---@param tag string
	local function makeEntry(tag)
		return string.format([[
local native = require("pkg-hot-error.native")
_G.runs = (_G.runs or 0) + 1
local f = assert(io.open(arg[1], "a"))
f:write("%s " .. native .. " runs=" .. _G.runs .. "\n")
f:close()
-- arg[2] is a marker the test owns: while it exists, every run fails.
if io.open(arg[2]) then error("app boom") end
while true do
	package.hot.poll()
end
]], tag)
	end

	fs.write(path.join(dir, "src", "init.lua"), makeEntry("run"))

	local logFile = path.join(tmpBase, "pkg-hot-error.log")
	fs.write(logFile, "")
	local failMarker = path.join(tmpBase, "pkg-hot-error.fail")
	fs.delete(failMarker)

	withChild({ "run", "--hot", "--", logFile, failMarker }, dir, function()
		test.truthy(waitForLog(logFile, "run native-v1 runs=1", 15000), "initial run missing from log")

		-- Drive the app into an error: the next change has to recover, and it
		-- cannot do that by dropping modules inside the state the error left
		-- behind (native.lua would re-declare its type and fail).
		fs.write(failMarker, "")
		fs.write(path.join(dir, "src", "init.lua"), makeEntry("run2"))
		test.truthy(waitForLog(logFile, "run2 native-v1 runs=2", 15000),
			"the entry did not re-run into the failure: " .. (fs.read(logFile) or ""))

		-- Fix the cause and change the FFI module: the app must come back in a
		-- rebuilt state, which shows in the counter restarting at 1.
		fs.delete(failMarker)
		fs.write(path.join(dir, "src", "native.lua"), [==[
local ffi = require("ffi")
ffi.cdef[[ typedef struct { int marker; } pkg_hot_error_probe; ]]
return "native-v2"
]==])
		test.truthy(waitForLog(logFile, "run2 native-v2 runs=1", 15000),
			"the app did not recover in a fresh state: " .. (fs.read(logFile) or ""))
	end)
end)

test.it("lde run --hot does not interrupt a program that never yields", function()
	local dir = makePackage("pkg-hot-blocking")
	fs.write(path.join(dir, "src", "utilmod.lua"), 'return "v1"')
	fs.write(path.join(dir, "src", "init.lua"), [[
local util = require("pkg-hot-blocking.utilmod")

local f = assert(io.open(arg[1], "a"))
f:write("run " .. util .. "\n")
f:close()

while true do end
]])

	local logFile = path.join(tmpBase, "pkg-hot-blocking.log")
	fs.write(logFile, "")

	withChild({ "run", "--hot", "--", logFile }, dir, function()
		test.truthy(waitForLog(logFile, "run v1", 15000), "initial run missing from log")

		fs.write(path.join(dir, "src", "utilmod.lua"), 'return "v2"')
		sleep(1200)

		-- Like bun --hot: a program that never hands control back keeps running
		-- the code it started with, and the watcher simply waits.
		test.falsy((fs.read(logFile) or ""):find("v2", 1, true),
			"a program that never yields must not be reloaded")
	end)
end)

test.it("lde run --hot reports reloads to package.hot.accept", function()
	local dir = makePackage("pkg-hot-accept")
	fs.write(path.join(dir, "src", "utilmod.lua"), 'return "v1"')
	fs.write(path.join(dir, "src", "init.lua"), [[
local util = require("pkg-hot-accept.utilmod")
_G.runs = (_G.runs or 0) + 1

local function log(line)
	local f = assert(io.open(arg[1], "a"))
	f:write(line .. "\n")
	f:close()
end

if package.hot then
	package.hot.accept(|m| -> log("accepted " .. m))
end

log("run " .. util .. " runs=" .. _G.runs)
]])

	local logFile = path.join(tmpBase, "pkg-hot-accept.log")
	fs.write(logFile, "")

	withChild({ "run", "--hot", "--", logFile }, dir, function()
		test.truthy(waitForLog(logFile, "run v1 runs=1", 15000), "initial run missing from log")
		test.falsy(fs.read(logFile):find("accepted", 1, true), "nothing must be accepted before a change")

		-- Different size, so the rebuild stamp's mtime/size fast path can't mask it.
		fs.write(path.join(dir, "src", "utilmod.lua"), 'return "version-2"')

		-- No trailing newline in the needle: the app writes the log in text mode
		-- (CRLF on Windows) and fs.read returns the raw bytes. The reload is
		-- asserted first, so a failure says whether the patch or the reporting
		-- broke.
		test.truthy(waitForLog(logFile, "run version-2 runs=2", 15000), "hot reload did not re-run the entry")
		test.truthy(waitForLog(logFile, "accepted pkg-hot-accept.utilmod", 15000),
			"the accept callback did not get the changed module's require path")

		-- One notification per reload: the entry re-registers on every run, so
		-- its previous registration must not fire a second time.
		local content = fs.read(logFile) or ""
		local _, count = content:gsub("accepted pkg%-hot%-accept%.utilmod\r?\n", "")
		test.equal(count, 1, "the accept callback must fire once per reload")
	end)
end)

test.it("lde <script> --hot works outside a package", function()
	local dir = path.join(tmpBase, "bare-hot")
	fs.mkdir(dir)
	fs.write(path.join(dir, "test.lua"), makeEntry("utilmod"))
	fs.write(path.join(dir, "utilmod.lua"), 'return "u1"')

	local logFile = path.join(tmpBase, "bare-hot.log")
	fs.write(logFile, "")

	withChild({ "./test.lua", "--hot", "--", logFile }, dir, function()
		test.truthy(waitForLog(logFile, "run u1 runs=1", 15000), "initial run missing from log")

		fs.write(path.join(dir, "utilmod.lua"), 'return "u2"')

		test.truthy(waitForLog(logFile, "run u2 runs=2", 15000), "hot reload did not pick up u2 in-place")
	end)
end)

	test.it("lde run --watch restarts with a fresh state", function()
	local dir = makePackage("pkg-watch")
	fs.write(path.join(dir, "src", "utilmod.lua"), 'return "v1"')
	fs.write(path.join(dir, "src", "init.lua"), makeEntry("pkg-watch.utilmod"))

	local logFile = path.join(tmpBase, "pkg-watch.log")
	fs.write(logFile, "")

	withChild({ "run", "--watch", "--", logFile }, dir, function()
		test.truthy(waitForLog(logFile, "run v1 runs=1", 15000), "initial run missing from log")

		fs.write(path.join(dir, "src", "utilmod.lua"), 'return "v2"')

		-- The counter must be 1: --watch tears down the state and re-creates it,
		-- so _G.runs starts over even though the module picked up v2.
		test.truthy(waitForLog(logFile, "run v2 runs=1", 15000), "watch restart did not reset the state")
	end)
end)

test.it("lde run --hot rebuilds and reloads a build.lua package", function()
	local dir = makePackage("pkg-hot-build")
	-- defaultBuildFn copies src/ into the output dir first, then runs build.lua;
	-- the preReload hook re-runs this on every hot reload (stamp-gated).
	fs.write(path.join(dir, "src", "utilmod.lua"), 'return "v1"')
	fs.write(path.join(dir, "build.lua"), [==[
local f = assert(io.open(os.getenv("LDE_OUTPUT_DIR") .. "/init.lua", "w"))
f:write([[
local u = require("pkg-hot-build.utilmod")
_G.runs = (_G.runs or 0) + 1
local f = assert(io.open(arg[1], "a"))
f:write("build-hot " .. u .. " runs=" .. _G.runs .. "\n")
f:close()
]])
f:close()
]==])

	local logFile = path.join(tmpBase, "pkg-hot-build.log")
	fs.write(logFile, "")

	withChild({ "run", "--hot", "--", logFile }, dir, function()
		test.truthy(waitForLog(logFile, "build-hot v1 runs=1", 15000), "initial run missing from log")

		-- Change the dep module: the preReload rebuild must refresh the copy in
		-- target/ (the stamp sees the src change) before the reload re-runs.
		-- Different size so the mtime/size fast path can't mask the change.
		fs.write(path.join(dir, "src", "utilmod.lua"), 'return "version-2"')

		test.truthy(waitForLog(logFile, "build-hot version-2 runs=2", 15000),
			"hot reload did not rebuild and reload the changed module")
	end)
end)

test.it("lde test --watch re-runs the suite when a test file changes", function()
	local dir = makePackage("pkg-test-watch")
	fs.mkdir(path.join(dir, "tests"))
	-- The test file counts its own executions in the package dir (the runner's
	-- cwd), so the watcher's re-runs are observable without capturing stdout.
	fs.write(path.join(dir, "tests", "counter.test.lua"), [[
local test = require("lde-test")
local f = assert(io.open("watch-count.txt", "a"))
f:write("x")
f:close()
test.it("passes", function() end)
]])
	local countPath = path.join(dir, "watch-count.txt")
	fs.write(countPath, "")

	withChild({ "test", "--watch" }, dir, function()
		test.truthy(waitForLog(countPath, "x", 15000), "initial test run missing")
		test.equal(fs.read(countPath), "x")

		-- Touch the test file: the watcher must re-run the suite.
		fs.write(path.join(dir, "tests", "counter.test.lua"), [[
local test = require("lde-test")
local f = assert(io.open("watch-count.txt", "a"))
f:write("x")
f:close()
test.it("passes", function() end)
-- touched
]])

		test.truthy(waitForCount(countPath, "x", 2, 15000), "test suite did not re-run after the file changed")
	end)
end)

-- Teal/Moonscript sources compile to .lua under target/, so a src/*.tl change
-- must invalidate the compiled module (and a broken compile must not wedge the
-- hot loop — the next fix must be picked up).
local TEAL_V1 = [[
local f = assert(io.open(arg[1], "a"))
f:write("teal v1\n")
f:close()
]]
local TEAL_V2 = [[
local f = assert(io.open(arg[1], "a"))
f:write("teal v2\n")
f:close()
]]
local TEAL_FIXED = [[
local f = assert(io.open(arg[1], "a"))
f:write("teal fixed\n")
f:close()
]]

test.it("lde run --hot reloads a Teal entry", function()
	local dir = makePackage("pkg-teal-hot")
	fs.write(path.join(dir, "src", "init.tl"), TEAL_V1)

	local logFile = path.join(tmpBase, "pkg-teal-hot.log")
	fs.write(logFile, "")

	withChild({ "run", "--hot", "--", logFile }, dir, function()
		test.truthy(waitForLog(logFile, "teal v1", 20000), "initial Teal run missing from log")

		fs.write(path.join(dir, "src", "init.tl"), TEAL_V2)

		test.truthy(waitForLog(logFile, "teal v2", 20000), "Teal hot reload did not pick up the change")
	end)
end)

test.it("lde run --hot recovers after a Teal syntax error is fixed", function()
	local dir = makePackage("pkg-teal-err")
	fs.write(path.join(dir, "src", "init.tl"), TEAL_V1)

	local logFile = path.join(tmpBase, "pkg-teal-err.log")
	fs.write(logFile, "")

	withChild({ "run", "--hot", "--", logFile }, dir, function()
		test.truthy(waitForLog(logFile, "teal v1", 20000), "initial Teal run missing from log")

		-- Break the source: the rebuild fails and the hot loop must keep
		-- watching (not wedge on the failed build).
		fs.write(path.join(dir, "src", "init.tl"), "local x: number = \n")
		sleep(800)

		-- Fix it: the next change must rebuild and re-run.
		fs.write(path.join(dir, "src", "init.tl"), TEAL_FIXED)

		test.truthy(waitForLog(logFile, "teal fixed", 20000), "hot reload did not recover after the syntax error was fixed")
	end)
end)

test.it("lde run --hot reloads a Moonscript entry", function()
	local dir = makePackage("pkg-moon-hot")
	fs.write(path.join(dir, "src", "init.moon"), [==[
f = assert(io.open(arg[1], "a"))
f\write("moon v1\n")
f\close()
]==])

	local logFile = path.join(tmpBase, "pkg-moon-hot.log")
	fs.write(logFile, "")

	withChild({ "run", "--hot", "--", logFile }, dir, function()
		test.truthy(waitForLog(logFile, "moon v1", 20000), "initial Moonscript run missing from log")

		fs.write(path.join(dir, "src", "init.moon"), [==[
f = assert(io.open(arg[1], "a"))
f\write("moon v2\n")
f\close()
]==])

		test.truthy(waitForLog(logFile, "moon v2", 20000), "Moonscript hot reload did not pick up the change")
	end)
end)
