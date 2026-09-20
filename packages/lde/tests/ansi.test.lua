local test = require("lde-test")
local env = require("env")

--- Set an env var, reload ansi so its color detection re-runs, run fn, then
--- restore the previous value and drop the module again.
---@param name string
---@param value string?
---@param fn fun()
local function withEnv(name, value, fn)
	local before = env.var(name)
	env.set(name, value)
	package.loaded["ansi"] = nil
	local ok, err = pcall(fn)
	env.set(name, before)
	package.loaded["ansi"] = nil
	if not ok then error(err, 2) end
end

test.it("NO_COLOR strips ANSI escapes", function()
	withEnv("NO_COLOR", "1", function()
		local ansi = require("ansi")
		test.equal(ansi.format("{red}x"), "x")
		test.equal(ansi.colorize("green", "y"), "y")
	end)
end)

test.it("CLICOLOR_FORCE emits ANSI escapes", function()
	withEnv("CLICOLOR_FORCE", "1", function()
		local ansi = require("ansi")
		test.includes(ansi.format("{red}x"), "\27[31m")
	end)
end)

test.it("orange uses the extended-color ANSI code", function()
	withEnv("CLICOLOR_FORCE", "1", function()
		local ansi = require("ansi")
		-- 38;5;208 is the stock 256-color orange (there's no base-16 orange);
		-- it's what the progress bar uses for its red→orange→yellow→green steps.
		test.includes(ansi.colorize("orange", "x"), "\27[38;5;208m")
	end)
end)

test.it("GitHub Actions emits ANSI escapes", function()
	withEnv("GITHUB_ACTIONS", "true", function()
		local ansi = require("ansi")
		test.includes(ansi.format("{red}x"), "\27[31m")
	end)
end)

test.it("NO_COLOR wins over GitHub Actions", function()
	withEnv("GITHUB_ACTIONS", "true", function()
		withEnv("NO_COLOR", "1", function()
			local ansi = require("ansi")
			test.equal(ansi.format("{red}x"), "x")
		end)
	end)
end)

--
-- ansi.supportsEmoji
--

test.it("NO_EMOJI disables emoji", function()
	withEnv("NO_EMOJI", "1", function()
		local ansi = require("ansi")
		test.falsy(ansi.supportsEmoji())
	end)
end)

test.it("NO_EMOJI=0 keeps emoji enabled", function()
	withEnv("NO_EMOJI", "0", function()
		withEnv("TERM", "xterm-256color", function()
			withEnv("LANG", "en_US.UTF-8", function()
				local ansi = require("ansi")
				test.truthy(ansi.supportsEmoji())
			end)
		end)
	end)
end)

test.it("dumb terminals disable emoji", function()
	withEnv("TERM", "dumb", function()
		local ansi = require("ansi")
		test.falsy(ansi.supportsEmoji())
	end)
end)

--
-- ansi.progress / ansi.installProgress (work diagnostics, on stderr)
--

--- Capture both output streams while fn runs. Progress is diagnostics and
--- belongs on stderr; stdout is the command's own data, so it must stay clean.
--- Both the io.write function and the stream handles are stubbed: ansi writes
--- through the handle it picked.
---@param fn fun()
---@return string stdout
---@return string stderr
local function captureStreams(fn)
	local stdoutBuf, stderrBuf = {}, {}
	local oldWrite, oldStdout, oldStderr = io.write, io.stdout, io.stderr

	local function sink(buf)
		return {
			write = function(_, ...)
				for i = 1, select("#", ...) do buf[#buf + 1] = tostring(select(i, ...)) end
				return true
			end,
			flush = function() end,
		}
	end

	io.write = function(...)
		for i = 1, select("#", ...) do stdoutBuf[#stdoutBuf + 1] = tostring(select(i, ...)) end
	end
	io.stdout, io.stderr = sink(stdoutBuf), sink(stderrBuf)

	local ok, err = pcall(fn)
	io.write, io.stdout, io.stderr = oldWrite, oldStdout, oldStderr
	if not ok then error(err, 0) end
	return table.concat(stdoutBuf), table.concat(stderrBuf)
end

-- The live region only renders on a terminal. Pin the probe so the rendering
-- path under test doesn't depend on how the suite's output is attached (a pty
-- renders frames, a pipe doesn't).
test.it("installProgress writes its summary to stderr, not stdout", function()
	local ansi = require("ansi")
	local wasStderrTTY = ansi.isStderrTTY
	ansi.isStderrTTY = false

	local stdout, stderr = captureStreams(function()
		local p = ansi.installProgress("Downloading dependencies")
		p:update(0.5, "1/2")
		p:setCurrent("curl-sys")
		p:setCurrent("git2-sys")
		p:tick()
		p:finish("curl-sys")
		p:finish("git2-sys")
		p:done("2 packages installed")
	end)

	ansi.isStderrTTY = wasStderrTTY
	test.equal(stdout, "", "install progress must not write to stdout")
	test.includes(stderr, "2 packages installed")
	-- No per-dependency lines and no live-line frames: an install prints
	-- exactly one line.
	test.falsy(stderr:find("curl%-sys", 1, true))
	test.falsy(stderr:find("1/2", 1, true))
end)

test.it("ansi.progress writes to stderr by default, and to stdout when asked", function()
	local ansi = require("ansi")
	local wasStderrTTY = ansi.isStderrTTY
	ansi.isStderrTTY = false

	-- Default: a download's lines are diagnostics, so stdout stays clean for the
	-- caller (`eval "$(lde completion bash)"`, `lde <tool> | ...`).
	local stdout, stderr = captureStreams(function()
		local p = ansi.progress("Downloading luajit for macos-aarch64", { indent = false })
		p:done("Downloaded luajit for macos-aarch64")
	end)
	test.includes(stderr, "Downloaded luajit for macos-aarch64")
	test.equal(stdout, "", "a download must not write to stdout")

	-- The test reporter's progress is its report, so it opts back into stdout.
	local reporterStdout, reporterStderr = captureStreams(function()
		ansi.progress("a test", { stream = "stdout" }):done("a test")
	end)
	ansi.isStderrTTY = wasStderrTTY
	test.includes(reporterStdout, "a test")
	test.equal(reporterStderr, "")
end)

test.it("ansi.isQuiet silences progress output entirely", function()
	local ansi = require("ansi")
	local wasQuiet = ansi.isQuiet
	ansi.isQuiet = true

	local stdout, stderr = captureStreams(function()
		local p = ansi.progress("Downloading luajit for macos-aarch64", { indent = false })
		p:update(0.5, "1.2 MB")
		p:setLabel("Downloading luajit for macos-aarch64")
		p:done("Downloaded luajit for macos-aarch64")
		p:fail("Downloaded luajit for macos-aarch64")
	end)

	ansi.isQuiet = wasQuiet
	test.equal(stdout .. stderr, "", "no progress output may reach the terminal in quiet mode")
end)

-- Regression: ansi.now() must be a wall clock. A CPU-time source (which is what
-- FreeBSD's clock id 1 = CLOCK_VIRTUAL silently is) never advances across a
-- sleep, so elapsed times read ~0 and the build timings report collapses.
test.it("now() advances during a sleep (wall clock, not CPU time)", function()
	local ansi = require("ansi")
	local ffi = require("ffi")
	local sleepMs
	if jit.os == "Windows" then
		pcall(ffi.cdef, "void Sleep(unsigned long dwMilliseconds);")
		sleepMs = function(ms) ffi.C.Sleep(ms) end
	else
		pcall(ffi.cdef, "int usleep(unsigned int usec);")
		sleepMs = function(ms) ffi.C.usleep(ms * 1000) end
	end

	local start = ansi.now()
	sleepMs(5)
	local elapsed = ansi.now() - start
	test.truthy(elapsed >= 0.004, "expected ~5ms of wall time, got " .. tostring(elapsed) .. "s")
end)
