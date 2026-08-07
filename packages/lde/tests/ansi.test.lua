local test = require("lde-test")

local env = require("env")
local path = require("path")
local process = require("process")

local execPath = assert(env.execPath())

-- The -e children need a package context (target/ on package.path) to resolve
-- ansi; derive the suite's own package dir so this works no matter where the
-- suite was launched from.
local modulesDir = package.path:match("^([^;]+)/%?%.lua")
local pkgDir = modulesDir and path.dirname(modulesDir) or env.cwd()

-- The spawned children inherit a pipe for stdout, so isatty is false there;
-- the env vars below pin the color decision regardless of the ambient
-- environment (e.g. CI vars in the parent). The -e chunk is wrapped in a
-- do-block so the guest doesn't echo the chunk's return value.

test.it("NO_COLOR strips ANSI escapes even when forced", function()
	local code, out = process.exec(execPath, {
		"-e", 'do io.write(require("ansi").format("{red}x")) end'
	}, { cwd = pkgDir, env = { NO_COLOR = "1" } })
	test.truthy(code == 0)
	test.equal(out, "x")
end)

test.it("CLICOLOR_FORCE emits ANSI escapes on non-tty output", function()
	local code, out = process.exec(execPath, {
		"-e", 'do io.write(require("ansi").format("{red}x")) end'
	}, { cwd = pkgDir, env = { CLICOLOR_FORCE = "1" } })
	test.truthy(code == 0)
	test.includes(out or "", "\27[31m")
end)

test.it("GitHub Actions renders ANSI escapes without a tty", function()
	local code, out = process.exec(execPath, {
		"-e", 'do io.write(require("ansi").format("{red}x")) end'
	}, { cwd = pkgDir, env = { GITHUB_ACTIONS = "true" } })
	test.truthy(code == 0)
	test.includes(out or "", "\27[31m")
end)
