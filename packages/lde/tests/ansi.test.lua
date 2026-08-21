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
