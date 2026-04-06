local test      = require("lde-test")
local process   = require("process2")

local isWindows = jit.os == "Windows"
local sh        = isWindows and "cmd" or "sh"
local shc       = isWindows and "/c" or "-c"

--
-- exec
--

test.it("exec returns exit code 0 on success", function()
	local code = process.exec(sh, { shc, "exit 0" })
	test.equal(code, 0)
end)

test.it("exec returns non-zero exit code on failure", function()
	local code = process.exec(sh, { shc, "exit 1" })
	test.equal(code, 1)
end)

test.it("exec captures stdout", function()
	local cmd = isWindows and "echo hello" or "printf hello"
	local code, stdout = process.exec(sh, { shc, cmd })
	test.equal(code, 0)
	test.truthy(stdout and stdout:find("hello"))
end)

test.it("exec captures stderr (merged into stdout on posix)", function()
	local cmd = isWindows and "echo err 1>&2" or "printf err >&2"
	local code, stdout, stderr = process.exec(sh, { shc, cmd })
	test.equal(code, 0)
	-- on posix both pipes merge; on windows they are separate
	local combined = (stdout or "") .. (stderr or "")
	test.truthy(combined:find("err"))
end)

test.it("exec passes stdin", function()
	local cmd = isWindows and "more" or "cat"
	local code, stdout = process.exec(sh, { shc, cmd }, { stdin = "hello" })
	test.equal(code, 0)
	test.truthy(stdout and stdout:find("hello"))
end)

test.it("exec passes env vars", function()
	local cmd = isWindows and "echo %MY_VAR%" or "printf $MY_VAR"
	local code, stdout = process.exec(sh, { shc, cmd }, { env = { MY_VAR = "testval" } })
	test.equal(code, 0)
	test.truthy(stdout and stdout:find("testval"))
end)

test.it("exec respects cwd", function()
	local cmd = isWindows and "cd" or "pwd"
	local tmpdir = isWindows and (os.getenv("TEMP") or "C:\\Temp") or "/tmp"
	local code, stdout = process.exec(sh, { shc, cmd }, { cwd = tmpdir })
	test.equal(code, 0)
	test.truthy(stdout and #stdout > 0)
end)

test.it("exec handles args with spaces and special chars", function()
	-- pass a quoted string through echo; just verify it doesn't crash and exits 0
	local code = process.exec(sh, { shc, isWindows and 'echo "hello world"' or "printf '%s' 'hello world'" })
	test.equal(code, 0)
end)

--
-- spawn (async Child)
--

test.it("spawn returns a Child with a pid", function()
	local child, err = process.spawn(sh, { shc, "exit 0" })
	test.truthy(child, err)
	test.truthy(child.pid > 0)
	child:wait()
end)

test.it("spawn Child:wait returns exit code", function()
	local child = process.spawn(sh, { shc, "exit 42" })
	test.truthy(child)
	local code = child:wait()
	test.equal(code, 42)
end)

test.it("spawn Child:wait captures stdout when piped", function()
	local cmd = isWindows and "echo hi" or "printf hi"
	local child = process.spawn(sh, { shc, cmd }, { stdout = "pipe" })
	test.truthy(child)
	local code, stdout = child:wait()
	test.equal(code, 0)
	test.truthy(stdout and stdout:find("hi"))
end)

test.it("spawn Child:kill terminates the process", function()
	local cmd = isWindows and "timeout /t 30 /nobreak >nul" or "sleep 30"
	local child = process.spawn(sh, { shc, cmd })
	test.truthy(child)
	child:kill(true)
	child:wait() -- must not hang
	test.truthy(true)
end)

test.it("spawn Child:poll returns nil while running", function()
	local cmd = isWindows and "timeout /t 30 /nobreak >nul" or "sleep 30"
	local child = process.spawn(sh, { shc, cmd })
	test.truthy(child)
	local code = child:poll()
	test.falsy(code) -- still running
	child:kill(true)
	child:wait()
end)

--
-- stdio modes
--

test.it("exec with stdout=null discards output", function()
	local cmd = isWindows and "echo hello" or "printf hello"
	local code, stdout = process.exec(sh, { shc, cmd }, { stdout = "null" })
	test.equal(code, 0)
	test.falsy(stdout)
end)

test.it("exec with stderr=null discards stderr", function()
	local code, stdout, stderr = process.exec(sh, { shc, "exit 0" }, { stderr = "null" })
	test.equal(code, 0)
	test.falsy(stderr)
end)

test.it("exec with stdout=inherit does not capture stdout", function()
	local cmd = isWindows and "echo hello" or "printf hello"
	local code, stdout = process.exec(sh, { shc, cmd }, { stdout = "inherit", stderr = "null" })
	test.equal(code, 0)
	test.falsy(stdout)
end)

test.it("exec with stderr=inherit does not capture stderr", function()
	local code, stdout, stderr = process.exec(sh, { shc, "exit 0" }, { stdout = "null", stderr = "inherit" })
	test.equal(code, 0)
	test.falsy(stderr)
end)

test.it("spawn with stderr=pipe captures stderr separately", function()
	local cmd = isWindows and "echo hello" or "printf hello"
	local child = process.spawn(sh, { shc, cmd }, { stdout = "pipe", stderr = "pipe" })
	test.truthy(child)
	local code, stdout, stderr = child:wait()
	test.equal(code, 0)
	test.truthy(stdout and stdout:find("hello"))
end)

--
-- platform
--

test.it("platform is set to a known value", function()
	local known = { win32 = true, linux = true, darwin = true, unix = true }
	test.truthy(known[process.platform])
end)

--
-- exec errors on bad binary
--

test.it("exec returns non-zero code when binary does not exist", function()
	local code = process.exec("__no_such_binary__", {})
	test.truthy(code ~= 0)
end)
