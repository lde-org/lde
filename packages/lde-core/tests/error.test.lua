-- Unit tests for lde-core.error: the error value, raise/classification, and
-- the boundary renderer (clean message vs crash screen).
local test = require("lde-test")

local errorlib = require("lde-core.error")

---@param s string
---@return string
local function plain(s)
	return ((s or ""):gsub("\27%[[0-9;]*m", ""))
end

--- Run fn with os.exit stubbed to a throw and stderr captured in memory. The
--- boundary writes errors to stderr (stdout is the command's data) through
--- io.stderr, so capture by swapping in a sink — no temp files (io.tmpfile is
--- nil on Android).
--- Returns the captured text and the exit code passed to os.exit (nil if
--- os.exit was never called and fn returned normally).
---@param fn fun()
---@return string text
---@return integer? exitCode
local function isCapture(fn)
	local buf = {}
	local prevStderr = io.stderr
	local prevExit = os.exit
	io.stderr = {
		write = function(_, ...)
			for i = 1, select("#", ...) do buf[#buf + 1] = tostring(select(i, ...)) end
			return true
		end,
		flush = function() end,
	}
	os.exit = function(code)
		error("CAPTURED-EXIT:" .. tostring(code), 0)
	end
	local ok, err = pcall(fn)
	os.exit = prevExit
	io.stderr = prevStderr
	local text = table.concat(buf)
	if ok then return text, nil end
	local marker = tostring(err):match("CAPTURED%-EXIT:(%d+)")
	test.truthy(marker, "unexpected error escaped capture: " .. tostring(err))
	return text, tonumber(marker)
end

test.it("raise throws a known error with __tostring", function()
	local ok, err = pcall(errorlib.raise, "boom")
	test.falsy(ok)
	test.truthy(errorlib.isKnown(err))
	test.equal(errorlib.message(err), "boom")
	test.equal(tostring(err), "boom")
end)

test.it("raise re-raises an existing error unchanged", function()
	local e = errorlib.new("original")
	local ok, err = pcall(errorlib.raise, e)
	test.falsy(ok)
	test.truthy(err == e)
end)

test.it("non-error values are not known errors", function()
	test.falsy(errorlib.isKnown("string error"))
	test.falsy(errorlib.isKnown({}))
	test.falsy(errorlib.isKnown(nil))
end)

test.it("known errors render a clean message and exit 1", function()
	local text, code = isCapture(function()
		errorlib.show(errorlib.new("clean message"), "ignored trace")
	end)
	test.equal(code, 1)
	test.includes(plain(text), "error: clean message")
	test.falsy(text:find("lde crashed", 1, true))
	test.falsy(text:find("ignored trace", 1, true))
end)

test.it("hints render under the message", function()
	local text = isCapture(function()
		errorlib.show(errorlib.new("some message", { hint = "do the thing" }))
	end)
	test.includes(plain(text), "do the thing")
end)

test.it("unexpected errors render the crash screen and exit 2", function()
	local text, code = isCapture(function()
		errorlib.show({ some = "bug" }, "fake traceback line")
	end)
	test.equal(code, 2)
	test.includes(plain(text), "lde crashed")
	test.includes(plain(text), "github.com/lde-org/lde/issues")
	test.includes(plain(text), "fake traceback line")
end)
