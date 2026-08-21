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
-- The child's stdout/stderr are discarded: the tests observe the session
-- through log files the app writes, and the watcher's "Watching..." /
-- "Reloaded:" chatter would otherwise pollute the test runner's output.
---@param args string[]
---@param cwd string
---@param fn fun(child: process.Child)
local function withChild(args, cwd, fn)
	local child, err = process.spawn(ldePath, args, { cwd = cwd, stdout = "null", stderr = "null" })
	if not child then error("spawn failed: " .. tostring(err), 2) end ---@cast child process.Child
	local ok, perr = pcall(fn, child)
	child:kill()
	sleep(150)
	if not ok then error(perr, 2) end
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
