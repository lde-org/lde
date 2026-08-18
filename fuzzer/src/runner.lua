-- fuzzer/src/runner.lua
--
-- Spawns the binary under test with a deadline (kill on timeout) and
-- classifies the outcome. Every case must be a graceful "ok" or "clean
-- error": a crash screen, a leaked raw traceback, or a hang are all
-- findings.

local ffi = require("ffi")
local process = require("process")

local sleep
if jit.os == "Windows" then
	ffi.cdef "void Sleep(unsigned long dwMilliseconds);"
	sleep = function(ms) ffi.C.Sleep(ms) end
else
	ffi.cdef "int usleep(unsigned long usec);"
	sleep = function(ms) ffi.C.usleep(ms * 1000) end
end

---@class fuzz.RunResult
---@field exit integer? # process exit code; nil on timeout or spawn failure
---@field out string # merged stdout + stderr
---@field timedOut boolean
---@field spawnError string?

--- Run a command under a deadline, killing it if it exceeds.
--- stdin is always empty so interactive prompts see EOF instead of blocking.
---@param bin string
---@param args string[]
---@param opts { cwd?: string, timeoutMs?: integer }?
---@return fuzz.RunResult
local function run(bin, args, opts)
	opts = opts or {}
	local timeoutMs = opts.timeoutMs or 10000

	local child, serr = process.spawn(bin, args, {
		cwd = opts.cwd,
		stdin = "",
		stdout = "pipe",
		stderr = "pipe",
	})
	if not child then
		return { exit = nil, timedOut = false, spawnError = serr, out = "" }
	end

	local deadline = os.clock() + timeoutMs / 1000
	while true do
		local code = child:poll()
		if code ~= nil then
			-- poll() reaps the child and returns the decoded exit code; wait()
			-- afterwards only drains the pipes (the status is already reaped,
			-- so its return value is meaningless).
			local _, stdout, stderr = child:wait()
			return { exit = code, timedOut = false, out = (stdout or "") .. (stderr or "") }
		end
		if os.clock() > deadline then
			child:kill(true)
			local _, stdout, stderr = child:wait()
			return { exit = nil, timedOut = true, out = (stdout or "") .. (stderr or "") }
		end
		sleep(2)
	end
end

--- Classify a run's outcome against the no-crash contract.
---
--- "eval"/"lua" cases run user code, so exit codes are whatever the user code
--- did and user-code errors are expected output — only the crash screen or a
--- leaked traceback count as bugs there. For regular command cases, exit 2 is
--- the boundary's dedicated bug exit code.
---@param kind "cmd" | "eval" | "lua"
---@param exit integer?
---@param out string
---@return string # "ok" | "clean_error" | "crash" | "raw_error"
local function classify(kind, exit, out)
	if out:find("lde crashed", 1, true) then return "crash" end
	if out:find("stack traceback", 1, true) then return "raw_error" end
	if kind == "cmd" and exit == 2 then return "crash" end
	if exit == 0 then return "ok" end
	return "clean_error"
end

---@param s string
---@return string
local function csvField(s)
	s = tostring(s)
	if s:find('[,%"\n]') then
		return '"' .. s:gsub('"', '""') .. '"'
	end
	return s
end

return { run = run, classify = classify, csvField = csvField }
