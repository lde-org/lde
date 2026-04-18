local test      = require("lde-test")
local highlight = require("readline.highlight")

local reset     = "\27[0m"
local magenta   = "\27[35m" -- keyword
local green     = "\27[32m" -- string
local yellow    = "\27[33m" -- number
local gray      = "\27[90m" -- comment
local blue      = "\27[34m" -- operator

local function strip(s)
	return s:gsub("\27%[[%d;]*m", "")
end

test.it("keywords are highlighted", function()
	local out = highlight("if")
	test.truthy(out:find(magenta, 1, true))
	test.equal(strip(out), "if")
end)

test.it("identifiers are not colored", function()
	local out = highlight("foo")
	test.equal(out, "foo")
end)

test.it("double-quoted strings are green", function()
	local out = highlight('"hello"')
	test.truthy(out:find(green, 1, true))
	test.equal(strip(out), '"hello"')
end)

test.it("single-quoted strings are green", function()
	local out = highlight("'hi'")
	test.truthy(out:find(green, 1, true))
	test.equal(strip(out), "'hi'")
end)

test.it("numbers are yellow", function()
	local out = highlight("42")
	test.truthy(out:find(yellow, 1, true))
	test.equal(strip(out), "42")
end)

test.it("hex numbers are yellow", function()
	local out = highlight("0xFF")
	test.truthy(out:find(yellow, 1, true))
	test.equal(strip(out), "0xFF")
end)

test.it("comments are gray", function()
	local out = highlight("-- comment")
	test.truthy(out:find(gray, 1, true))
	test.equal(strip(out), "-- comment")
end)

test.it("operators are blue", function()
	local out = highlight("+")
	test.truthy(out:find(blue, 1, true))
	test.equal(strip(out), "+")
end)

test.it("mixed line preserves text content", function()
	local line = "local x = 42 -- note"
	test.equal(strip(highlight(line)), line)
end)

test.it("highlight is passed through edit and does not corrupt result", function()
	local readline = require("readline")
	local i, out = 0, {}
	local result = readline.edit({
		prompt    = "> ",
		history   = {},
		highlight = highlight,
		readByte  = function()
			i = i + 1
			return ({ "l", "o", "c", "a", "l", " ", "x", "\r" })[i]
		end,
		write     = function(s) out[#out + 1] = s end
	})
	test.equal(result, "local x")
end)
