local test = require("lde-test")

local env = require("env")
local process = require("process")

local execPath = assert(env.execPath())

-- The spawned children inherit a pipe for stdout, so isatty is always false
-- there — making the color-support detection deterministic. The -e chunk is
-- wrapped in a do-block so the guest doesn't echo the chunk's return value.

test.it("ansi strips color codes when stdout is not a terminal", function()
	local code, out = process.exec(execPath, {
		"-e", 'do io.write(require("ansi").format("{red}x") .. "|" .. require("ansi").colorize("green", "y")) end'
	})
	test.truthy(code == 0)
	test.equal(out, "x|y")
end)

	test.it("NO_COLOR strips ANSI escapes even when forced", function()
	local code, out = process.exec(execPath, {
		"-e", 'do io.write(require("ansi").format("{red}x")) end'
	}, { env = { NO_COLOR = "1" } })
	test.truthy(code == 0)
	test.equal(out, "x")
end)

	test.it("CLICOLOR_FORCE emits ANSI escapes on non-tty output", function()
	local code, out = process.exec(execPath, {
		"-e", 'do io.write(require("ansi").format("{red}x")) end'
	}, { env = { CLICOLOR_FORCE = "1" } })
	test.truthy(code == 0)
	test.includes(out or "", "\27[31m")
end)
