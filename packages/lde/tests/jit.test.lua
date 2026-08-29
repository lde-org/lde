-- JIT diagnostics (`lde run --jit`): trace aborts — code that could not be
-- JIT-compiled — must be reported with the compiler's reason and a source
-- location, plus an end-of-run summary.
local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")
local process = require("process")

local ldePath = assert(env.execPath())

local tmpBase = path.join(env.tmpdir(), "lde-jit-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

---@param s string
---@return string
local function plain(s)
	return ((s or ""):gsub("\27%[[0-9;]*m", ""))
end

-- Creating a closure inside a hot loop emits the FNEW bytecode, which LuaJIT
-- cannot compile: recording aborts with "NYI: bytecode FNEW". The blank line
-- before the loop also exercises the snippet renderer (a splitter that
-- miscounts blank lines would show the wrong line's content). Deterministic
-- across LuaJIT builds.
local FNEW_APP = [[
local x = function() end

for i = 1, 100000 do
	local f = function() return i end
	local _ = f
end

print(x)
]]

test.it("--jit reports trace aborts with reasons and source locations", function()
	local dir = path.join(tmpBase, "fnew")
	fs.mkdir(dir)
	fs.write(path.join(dir, "app.lua"), FNEW_APP)

	local code, stdout, stderr = process.exec(ldePath, { "app.lua", "--jit" }, { cwd = dir })
	test.truthy(code == 0, "run must succeed")
	local text = plain((stdout or "") .. (stderr or ""))
	test.includes(text, "FNEW is NYI", "the abort reason must be decoded")
	-- The aborting bytecode is the FNEW on line 4 of FNEW_APP; the location
	-- must point at it exactly (funcinfo(func, pc).loc), not the function range.
	test.includes(text, "app.lua:4", "the abort location must name the exact line")
	-- The summary snippet must show the offending line's content (a line
	-- splitter that miscounts blank lines would render the wrong text).
	test.includes(text, "local f = function() return i end", "the snippet must show the aborting line")
	test.includes(text, "traces compiled", "the summary must be printed")
end)

test.it("--jit stays silent on JIT-friendly code", function()
	local dir = path.join(tmpBase, "clean")
	fs.mkdir(dir)
	fs.write(path.join(dir, "app.lua"), "local s = 0\nfor i = 1, 1000000 do s = s + i end\nprint(s)\n")

	local code, stdout, stderr = process.exec(ldePath, { "app.lua", "--jit" }, { cwd = dir })
	test.truthy(code == 0, "run must succeed")
	local text = plain((stdout or "") .. (stderr or ""))
	test.includes(text, "traces compiled, 0 aborted", "clean code must show zero aborts")
	test.falsy(text:find("NYI", 1, true), "no abort reasons on clean code")
end)
