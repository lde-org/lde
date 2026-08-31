-- Error-contract tests: the CLI must never leak raw tracebacks to the user.
-- Known errors (lde.error.raise) print a single clean "Error: ..." line and
-- exit non-zero; unexpected failures print the "lde crashed" screen (unit
-- tested in lde-core/tests/error.test.lua). This file is the black-box
-- contract against the compiled binary.
local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")
local process = require("process")

local ldePath = assert(env.execPath())

local tmpBase = path.join(env.tmpdir(), "lde-error-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

---@param s string
---@return string
local function plain(s)
	return ((s or ""):gsub("\27%[[0-9;]*m", ""))
end

---Run the binary, merging stdout and stderr.
---@param args string[]
---@param cwd string?
---@return integer code
---@return string out
local function run(args, cwd)
	local code, stdout, stderr = process.exec(ldePath, args, { cwd = cwd }) ---@cast code integer
	return code, (stdout or "") .. (stderr or "")
end

---@param args string[]
---@param fragment string
---@param cwd string?
local function expectCleanError(args, fragment, cwd)
	local code, out = run(args, cwd)
	local label = table.concat(args, " ")
	test.truthy(code ~= 0, "expected non-zero exit for: " .. label)
	local text = plain(out)
	test.includes(text, fragment)
	test.falsy(text:find("stack traceback", 1, true), "raw traceback leaked for: " .. label)
	test.falsy(text:find("lde crashed", 1, true), "crash screen shown for known error: " .. label)
end

test.it("unknown command is a clean error", function()
	expectCleanError({ "frobnicate" }, "Unknown command")
end)

test.it("unknown command suggests a close command", function()
	local code, out = run({ "isntall" })
	test.truthy(code ~= 0, "typo'd command must exit non-zero")
	test.includes(plain(out), "Did you mean `install`?")

	-- A partial command lists every matching name.
	code, out = run({ "com" })
	test.truthy(code ~= 0, "partial command must exit non-zero")
	test.includes(plain(out), "Did you mean one of: `compile`, `completion`?")

	-- A command far from any real name gets no suggestion.
	code, out = run({ "frobnicate" })
	test.truthy(code ~= 0)
	test.falsy(plain(out):find("Did you mean", 1, true), "garbage input must not get a suggestion")
end)

test.it("path-like unknown command reports the missing file", function()
	-- `lde ./x.lua` on a missing file must say the file is missing, not
	-- "Unknown command" (which reads like a command typo).
	expectCleanError({ "./nope.lua" }, "No file at path './nope.lua'", tmpBase)
	expectCleanError({ "../nope.lua" }, "No file at path '../nope.lua'", tmpBase)
	expectCleanError({ "/abs/nope.lua" }, "No file at path '/abs/nope.lua'", tmpBase)
	expectCleanError({ "~/nope.lua" }, "No file at path '~/nope.lua'", tmpBase)

	-- Non-path garbage still reads as a command typo.
	expectCleanError({ "frobnicate" }, "Unknown command", tmpBase)
end)

test.it("run errors name the file, not the truncated source", function()
	-- The entry chunk must be labeled with its path (the "@" convention) so
	-- syntax errors report "broken.lua:2: ..." instead of
	-- `[string "local a = 1..."]` (LuaJIT's fallback for a missing chunk name).
	local dir = path.join(tmpBase, "err-chunkname")
	fs.mkdir(dir)
	fs.write(path.join(dir, "broken.lua"), "local a = 1\nlocal b = \n")
	local code, out = run({ "./broken.lua" }, dir)
	test.truthy(code ~= 0, "syntax error must exit non-zero")
	local text = plain(out)
	test.includes(text, "broken.lua")
	test.falsy(text:find("[string", 1, true), "chunk label must be the file path, not the source text")
end)

test.it("run error caret sits directly under the failing line", function()
	-- Runtime error at line 3 of a 5-line file: the caret must point at the
	-- incident line, not drift to the bottom of the context window (which
	-- would put it under the last line shown instead).
	local dir = path.join(tmpBase, "err-caret")
	fs.mkdir(dir)
	fs.write(path.join(dir, "boom.lua"), "local x = 2\n\nfoo()\n\nlocal i = 1\n")
	local code, out = run({ "./boom.lua" }, dir)
	test.truthy(code ~= 0, "runtime error must exit non-zero")
	local text = plain(out)

	local incidentIdx, caretIdx
	local i = 0
	for line in text:gmatch("[^\n]+") do
		i = i + 1
		if line:match("^3 | foo%(%)") then incidentIdx = i end
		if line:match("^%s*%^%^%^") then caretIdx = i end
	end
	test.truthy(incidentIdx ~= nil, "incident line must be shown in the snippet")
	test.truthy(caretIdx ~= nil, "caret must be shown in the snippet")
	test.equal(caretIdx, incidentIdx + 1, "caret must sit on the line directly under the incident")
	-- The context window must continue below the caret, proving the caret was
	-- inserted after the failing line rather than appended after the window.
	test.truthy(text:find("5 | local i = 1", 1, true) ~= nil, "trailing context must still be shown")
end)

test.it("run error in a package maps target/<name> back to src/", function()
	-- The entry runs from target/<name>/init.lua but the error must point at
	-- the source the user wrote (src/init.lua). The package lives in a long
	-- path so the chunk name exceeds LuaJIT's short_src buffer and arrives
	-- truncated ("..." + tail) — the remap must survive the truncation.
	local dir = path.join(tmpBase, "err-remap-" .. string.rep("x", 48))
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), "print('hi')\nerror('boom in src')\n")
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "err-remap",
		version = "0.1.0",
		dependencies = {}
	}))
	local code, out = run({ "run" }, dir)
	test.truthy(code ~= 0, "runtime error must exit non-zero")
	local text = plain(out)
	test.falsy(text:find(path.join("target", "err%-remap"), 1), "snippet must not show the built target/ path")
	test.includes(text, path.join("src", "init.lua"), "snippet must point at the source the user wrote")
	test.falsy(text:find("stack traceback", 1, true), "raw traceback leaked for package run error")
end)

test.it("unknown help target suggests a close command", function()
	local code, out = run({ "help", "hlep" })
	test.truthy(code ~= 0, "typo'd help target must exit non-zero")
	test.includes(plain(out), "Did you mean `help`?")
end)

test.it("unknown help target is a clean error", function()
	expectCleanError({ "help", "frobnicate" }, "Unknown command")
	-- The --help fast path runs outside the error boundary; it must still fail
	-- cleanly instead of leaking a raw traceback.
	expectCleanError({ "--help", "frobnicate" }, "Unknown command")
end)

test.it("unknown completion shell is a clean error", function()
	expectCleanError({ "completion", "tcsh" }, "Unknown shell")
end)

test.it("missing command arguments are clean errors", function()
	expectCleanError({ "add" }, "Usage: lde add")
	expectCleanError({ "remove" }, "Usage: lde remove")
	expectCleanError({ "uninstall" }, "Usage: lde uninstall")
end)

test.it("invalid scaffold flags are clean errors", function()
	expectCleanError({ "new", "--type", "bogus", "x" }, "Invalid --type", tmpBase)
	expectCleanError({ "new", "--language", "rust", "x" }, "Invalid --language", tmpBase)
end)

test.it("new in a taken directory is a clean error", function()
	fs.mkdir(path.join(tmpBase, "error-taken"))
	expectCleanError({ "new", "error-taken" }, "already exists", tmpBase)
end)

test.it("commands outside a project are clean errors", function()
	expectCleanError({ "run" }, "No package found", tmpBase)
	expectCleanError({ "install" }, "No package found", tmpBase)
	expectCleanError({ "update" }, "No package found", tmpBase)
	expectCleanError({ "compile" }, "No package found", tmpBase)
	expectCleanError({ "tree" }, "No package found", tmpBase)
end)

test.it("update of an unknown dependency is a clean error", function()
	local dir = path.join(tmpBase, "error-update-project")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), 'return "error-update"')
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "error-update",
		version = "0.1.0",
		dependencies = {}
	}))
	expectCleanError({ "update", "nope" }, "Unknown dependency", dir)
end)

test.skipIf(jit.os == "Windows")("a deleted working directory is a clean error", function()
	-- Reproduce: cd into a dir, delete it out from under the shell, run lde.
	-- Relative FS ops then act on the orphaned directory but env.cwd()
	-- returns nil, which used to crash commands like `lde new` at
	-- path.resolve(nil, ...).
	local dir = path.join(tmpBase, "deleted-cwd")
	fs.mkdir(dir)
	local code, stdout, stderr = process.exec("sh", {
		"-c", 'cd "$1" && rmdir "$1" && exec "$2" new', "sh", dir, ldePath
	})
	local text = plain((stdout or "") .. (stderr or ""))
	test.truthy(code ~= 0, "expected non-zero exit in deleted cwd")
	test.includes(text, "Current working directory no longer exists")
	test.falsy(text:find("stack traceback", 1, true), "raw traceback leaked in deleted cwd")
	test.falsy(text:find("lde crashed", 1, true), "crash screen shown for deleted cwd")
end)
