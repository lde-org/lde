local test     = require("lde-test")
local readline = require("readline")
local ffi      = require("ffi")

-- raw mode (posix only)

if jit.os ~= "Windows" then
	local raw = require("readline.raw.posix")

	test.it("enterRaw sets VMIN=1 VTIME=0 and exitRaw restores", function()
		-- only meaningful on a real TTY; skip if fd 0 is not a tty
		ffi.cdef("int isatty(int fd);")
		if ffi.C.isatty(0) == 0 then return end

		local VMIN  = jit.os == "OSX" and 16 or 6
		local VTIME = jit.os == "OSX" and 17 or 5

		-- capture termios after enterRaw
		local Termios = ffi.typeof("struct termios")
		local t = Termios()
		raw.enterRaw()
		ffi.C.tcgetattr(0, t)
		local vmin  = tonumber(t.c_cc[VMIN])
		local vtime = tonumber(t.c_cc[VTIME])
		raw.exitRaw()

		test.equal(vmin,  1)
		test.equal(vtime, 0)
	end)
end

-- Helper: feed a sequence of byte strings, return {result, written}
local function run(bytes, hist)
	local i      = 0
	local out    = {}
	local result = readline.edit({
		prompt   = "> ",
		history  = hist or {},
		readByte = function()
			i = i + 1
			return bytes[i]
		end,
		write    = function(s) out[#out + 1] = s end
	})
	return result, table.concat(out)
end

-- Escape sequences
local UP    = "\x1b[A"
local DOWN  = "\x1b[B"
local RIGHT = "\x1b[C"
local LEFT  = "\x1b[D"
local HOME  = "\x1b[H"
local END_  = "\x1b[F"
local DEL   = "\x1b[3~"

local function keys(...)
	local t = {}
	for _, v in ipairs({ ... }) do
		if #v == 1 then
			t[#t + 1] = v
		else
			-- escape sequence: split into individual bytes
			for i = 1, #v do t[#t + 1] = v:sub(i, i) end
		end
	end
	return t
end

-- basic input

test.it("returns typed line on enter", function()
	local result = run(keys("h", "i", "\r"))
	test.equal(result, "hi")
end)

test.it("returns empty string on bare enter", function()
	local result = run(keys("\r"))
	test.equal(result, "")
end)

test.it("returns nil on Ctrl-D with empty line", function()
	local result = run(keys("\x04"))
	test.equal(result, nil)
end)

test.it("returns nil on Ctrl-C", function()
	local result = run(keys("a", "b", "\x03"))
	test.equal(result, nil)
end)

test.it("Ctrl-D on non-empty line does not exit", function()
	local result = run(keys("a", "\x04", "\r"))
	test.equal(result, "a")
end)

-- backspace

test.it("backspace deletes last char", function()
	local result = run(keys("a", "b", "\x7f", "\r"))
	test.equal(result, "a")
end)

test.it("backspace at start does nothing", function()
	local result = run(keys("\x7f", "a", "\r"))
	test.equal(result, "a")
end)

-- cursor movement + insert

test.it("left then insert puts char before cursor", function()
	local result = run(keys("a", "c", LEFT, "b", "\r"))
	test.equal(result, "abc")
end)

test.it("right moves cursor right", function()
	local result = run(keys("a", "b", LEFT, LEFT, RIGHT, "x", "\r"))
	test.equal(result, "axb")
end)

test.it("left at start does nothing", function()
	local result = run(keys("a", LEFT, LEFT, LEFT, "b", "\r"))
	test.equal(result, "ba")
end)

test.it("right at end does nothing", function()
	local result = run(keys("a", RIGHT, RIGHT, "b", "\r"))
	test.equal(result, "ab")
end)

-- home / end

test.it("home moves to start", function()
	local result = run(keys("a", "b", HOME, "x", "\r"))
	test.equal(result, "xab")
end)

test.it("end moves to end", function()
	local result = run(keys("a", "b", HOME, END_, "x", "\r"))
	test.equal(result, "abx")
end)

-- Ctrl-A / Ctrl-E

test.it("Ctrl-A moves to start", function()
	local result = run(keys("a", "b", "\x01", "x", "\r"))
	test.equal(result, "xab")
end)

test.it("Ctrl-E moves to end", function()
	local result = run(keys("a", "b", "\x01", "\x05", "x", "\r"))
	test.equal(result, "abx")
end)

-- Ctrl-K / Ctrl-U

test.it("Ctrl-W deletes word before cursor", function()
	local result = run(keys("foo", " ", "bar", "\x17", "\r"))
	test.equal(result, "foo ")
end)

test.it("Ctrl-W deletes through leading spaces", function()
	local result = run(keys("foo", "  ", "\x17", "\r"))
	test.equal(result, "")
end)

test.it("Ctrl-K kills to end of line", function()
	local result = run(keys("a", "b", "c", LEFT, "\x0b", "\r"))
	test.equal(result, "ab")
end)

test.it("Ctrl-U kills to start of line", function()
	local result = run(keys("a", "b", "c", LEFT, "\x15", "\r"))
	test.equal(result, "c")
end)

-- delete key

test.it("delete key removes char at cursor", function()
	local result = run(keys("a", "b", LEFT, DEL, "\r"))
	test.equal(result, "a")
end)

test.it("delete at end does nothing", function()
	local result = run(keys("a", DEL, "\r"))
	test.equal(result, "a")
end)

-- history

test.it("up recalls previous entry", function()
	local hist   = { "hello" }
	local result = run(keys(UP, "\r"), hist)
	test.equal(result, "hello")
end)

test.it("up then down restores current line", function()
	local hist   = { "prev" }
	local result = run(keys("n", "e", "w", UP, DOWN, "\r"), hist)
	test.equal(result, "new")
end)

test.it("up past start stays at oldest entry", function()
	local hist   = { "only" }
	local result = run(keys(UP, UP, UP, "\r"), hist)
	test.equal(result, "only")
end)

test.it("down past end stays at current line", function()
	local hist   = { "a" }
	local result = run(keys("x", DOWN, DOWN, "\r"), hist)
	test.equal(result, "x")
end)

test.it("completed line is appended to history", function()
	local hist = {}
	run(keys("f", "o", "o", "\r"), hist)
	test.equal(hist[1], "foo")
end)

test.it("empty line is not appended to history", function()
	local hist = {}
	run(keys("\r"), hist)
	test.equal(#hist, 0)
end)
