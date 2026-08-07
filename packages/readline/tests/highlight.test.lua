local test      = require("lde-test")
local ansi      = require("ansi")
local highlight = require("readline.highlight")

-- The codes ansi would emit in this environment (empty when colors are
-- disabled, e.g. piped output) — the tests must pass in both modes.
local function code(name)
	return ansi.colorize(name, ""):match("^\27%[[%d;]*m") or ""
end
local magenta = code("magenta") -- keyword
local green   = code("green")   -- string
local yellow  = code("yellow")  -- number
local gray    = code("gray")    -- comment
local blue    = code("blue")    -- operator

local function strip(s)
	return s:gsub("\27%[[%d;]*m", "")
end

test.it("keywords are highlighted", function()
	local out = highlight("if")
	test.truthy(out:find(magenta, 1, true))
	test.equal(strip(out), "if")
end)

test.it("const keyword is highlighted", function()
	local out = highlight("const x = 1")
	test.truthy(out:find(magenta, 1, true))
	test.equal(strip(out), "const x = 1")
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
