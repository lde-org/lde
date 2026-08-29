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
