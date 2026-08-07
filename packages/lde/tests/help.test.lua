local test = require("lde-test")

local ldecli = require("tests.lib.ldecli")

test.it("lde --help shows the main help", function()
	local ok, out = ldecli { "--help" }
	test.truthy(ok)
	test.includes(out, "Usage:")
	test.includes(out, "Commands:")
end)

test.it("lde help shows the main help", function()
	local ok, out = ldecli { "help" }
	test.truthy(ok)
	test.includes(out, "Usage:")
	test.includes(out, "Commands:")
end)

test.it("lde --help <command> shows that command's help", function()
	local ok, out = ldecli { "--help", "run" }
	test.truthy(ok)
	test.includes(out, "lde run")
	test.includes(out, "Options:")
	test.includes(out, "--watch")
end)

test.it("lde help <command> shows that command's help", function()
	local ok, out = ldecli { "help", "add" }
	test.truthy(ok)
	test.includes(out, "lde add")
	test.includes(out, "--git")
	test.includes(out, "Options:")
end)

test.it("lde help resolves aliases", function()
	local ok, out = ldecli { "help", "i" }
	test.truthy(ok)
	test.includes(out, "lde install")
	test.includes(out, "alias for")
end)

test.it("lde help <unknown> fails", function()
	local ok, out = ldecli { "help", "frobnicate" }
	test.falsy(ok)
	test.includes(out, "Unknown command")
end)

test.it("lde completion bash prints a bash script", function()
	local ok, out = ldecli { "completion", "bash" }
	test.truthy(ok)
	test.includes(out, "_lde()")
	test.includes(out, "complete -F _lde lde")
	test.includes(out, "lde __complete")
end)

test.it("lde completion zsh prints a zsh script", function()
	local ok, out = ldecli { "completion", "zsh" }
	test.truthy(ok)
	test.includes(out, "#compdef lde")
end)

test.it("lde completion fish prints a fish script", function()
	local ok, out = ldecli { "completion", "fish" }
	test.truthy(ok)
	test.includes(out, "complete -c lde")
end)

test.it("lde completion <unknown> fails", function()
	local ok, out = ldecli { "completion", "tcsh" }
	test.falsy(ok)
	test.includes(out, "Unknown shell")
end)

test.it("lde __complete suggests commands", function()
	local ok, out = ldecli { "__complete", "ru" }
	test.truthy(ok)
	test.includes(out, "run")
	test.falsy(out:find("repl", 1, false))
end)

test.it("lde __complete suggests flags after a command", function()
	local ok, out = ldecli { "__complete", "run", "--wa" }
	test.truthy(ok)
	test.includes(out, "--watch")
	test.falsy(out:find("--hot", 1, false))
end)

test.it("lde __complete suggests command names for help", function()
	local ok, out = ldecli { "__complete", "help", "r" }
	test.truthy(ok)
	test.includes(out, "run")
	test.includes(out, "remove")
end)

test.it("lde __complete returns nothing after --", function()
	local ok, out = ldecli { "__complete", "run", "--", "m" }
	test.truthy(ok)
	test.falsy(out and #out > 0)
end)

test.it("lde __complete returns nothing for a flag value position", function()
	local ok, out = ldecli { "__complete", "run", "--flamegraph", "pr" }
	test.truthy(ok)
	test.falsy(out and #out > 0)
end)
