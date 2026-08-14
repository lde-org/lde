local test = require("lde-test")

local clap = require("clap")

test.it("option does not consume -- as a value", function()
	local args = clap.parse({ "--profile", "--flamegraph", "--", "--cwd", "../..", "test" })

	test.truthy(args:flag("profile"))
	test.equal(args:option("flamegraph"), nil)
	test.equal(args:peek(), "--flamegraph")

	local dash, dashPos = args:flag("")
	test.truthy(dash)
	test.equal(dashPos, 1)

	local rest = args:drain(dashPos)
	test.equal(rest[1], "--flamegraph")
	test.equal(rest[2], "--cwd")
	test.equal(rest[3], "../..")
	test.equal(rest[4], "test")
end)

--
-- option()
--

test.it("option parses --key=value form and reports its position", function()
	local args = clap.parse({ "run", "--flamegraph=out.html", "--", "x" })

	local val, pos = args:option("flamegraph")
	test.equal(val, "out.html")
	test.equal(pos, 1) -- index of the element before the option key
	-- Only the option was consumed; the positionals remain ("run", "--", "x").
	test.equal(args:peek(), "run")
	test.equal(args:count(), 3)
end)

test.it("option stops scanning at -- (everything after is positional)", function()
	local args = clap.parse({ "run", "--", "--json", "out.json" })

	test.equal(args:option("json"), nil, "option after -- must not be consumed")
	test.equal(args:flag("json"), false)
	test.equal(args:peek(), "run")
end)

test.it("option does not consume when the next token is --", function()
	local args = clap.parse({ "--json", "--" })

	test.equal(args:option("json"), nil)
	-- The option key must survive so the caller can see it.
	test.equal(args:peek(), "--json")
end)

test.it("option returns nil for unknown keys without consuming anything", function()
	local args = clap.parse({ "--git", "url" })

	test.equal(args:option("path"), nil)
	test.equal(args:count(), 2)
end)

test.it("option consumes the first matching key and leaves later duplicates", function()
	local args = clap.parse({ "--path", "a", "--path", "b" })

	test.equal(args:option("path"), "a")
	test.equal(args:option("path"), "b")
	test.equal(args:count(), 0)
end)

--
-- flag() / flagShort()
--

test.it("flag ignores --key=value (it is an option, not a flag)", function()
	local args = clap.parse({ "--verbose=2" })

	test.equal(args:flag("verbose"), false)
	test.equal(args:count(), 1, "--key=value must not be consumed by flag()")
end)

test.it("flag stops scanning at --", function()
	local args = clap.parse({ "--", "--watch" })

	test.equal(args:flag("watch"), false)
	test.equal(args:peek(), "--")
end)

test.it("flagShort matches -x and stops at --", function()
	local args = clap.parse({ "-e", "print(1)", "--", "-e" })

	test.truthy(args:flagShort("e"))
	test.equal(args:peek(), "print(1)")
	test.equal(args:flagShort("e"), false, "-e after -- must not match")
end)

--
-- short()
--

test.it("short consumes -k value and -k=value forms", function()
	local args = clap.parse({ "-C", "pkg" })
	test.equal(args:short("C"), "pkg")
	test.equal(args:count(), 0)

	local eq = clap.parse({ "-C=pkg" })
	test.equal(eq:short("C"), "pkg")
	test.equal(eq:count(), 0)
end)

test.it("short returns nil without consuming when there is no value", function()
	local args = clap.parse({ "-C" })

	test.equal(args:short("C"), nil)
	test.equal(args:peek(), "-C")
end)

--
-- drain() / count()
--

test.it("drain() returns and clears every remaining token", function()
	local args = clap.parse({ "a", "b", "c" })

	local all = args:drain()
	test.equal(all[1], "a")
	test.equal(all[3], "c")
	test.equal(args:count(), 0)
end)

test.it("drain(start) returns tokens from start onward", function()
	local args = clap.parse({ "a", "b", "c" })

	local rest = args:drain(2)
	test.equal(rest[1], "b")
	test.equal(rest[2], "c")
	test.equal(args:count(), 1)
	test.equal(args:peek(), "a")
end)
