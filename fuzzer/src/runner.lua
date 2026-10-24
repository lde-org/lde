-- fuzzer/src/runner.lua
--
-- Spawns the binary under test with a deadline (kill on timeout) and
-- classifies the outcome. Every case must be a graceful "ok" or "clean
-- error": a crash screen, a leaked raw traceback, or a hang are all
-- findings.

local ffi = require("ffi")
local process = require("process")
local ansi = require("ansi")

--- Child handle shape, declared locally: the `process` class is only reachable
--- through a symlinked target dir here, which the checker cannot resolve.
---@class fuzzer.Child
---@field kill fun(self: fuzzer.Child, force: boolean?)
---@field wait fun(self: fuzzer.Child): number?, string?, string?
---@field poll fun(self: fuzzer.Child): number?

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
	if type(child) ~= "table" then
		return { exit = nil, timedOut = false, spawnError = serr, out = "" }
	end
	---@cast child fuzzer.Child

	local deadline = ansi.now() + timeoutMs / 1000
	while true do
		local code = child:poll()
		if code ~= nil then
			-- poll() reaps the child and returns the decoded exit code; wait()
			-- afterwards only drains the pipes (the status is already reaped,
			-- so its return value is meaningless).
			local _, stdout, stderr = child:wait()
			return { exit = code, timedOut = false, out = (stdout or "") .. (stderr or "") }
		end
		if ansi.now() > deadline then
			child:kill(true)
			-- Don't wait(): the killed process's grandchildren may still hold the
			-- pipe write ends (e.g. a compiler or git spawned mid-build), which
			-- would block the drain forever. Leak the fds instead — timeouts are
			-- rare and the output is discarded anyway.
			return { exit = nil, timedOut = true, out = "" }
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
local function classify(kind, exit, out)
	if out:find("lde crashed", 1, true) then return "crash" end
	if out:find("stack traceback", 1, true) then return "raw_error" end
	if kind == "cmd" and exit == 2 then return "crash" end
	if exit == 0 then return "ok" end
	return "clean_error"
end

---@param s string
local function csvField(s)
	s = tostring(s)
	if s:find('[,%"\n]') then
		return '"' .. s:gsub('"', '""') .. '"'
	end
	return s
end

--- Outcomes in the order the summary prints them.
local OUTCOMES = { "ok", "clean_error", "crash", "raw_error", "timeout", "spawn_error" }

--- Turn a run result into an outcome plus whether it breaks the no-crash
--- contract. A hang in user-code cases (eval/lua) is the user's own loop, so
--- only command-case timeouts and any spawn failure are findings.
---@param kind "cmd" | "eval" | "lua"
---@param res fuzz.RunResult
---@return string outcome
---@return boolean finding
local function evaluate(kind, res)
	if res.spawnError then return "spawn_error", true end
	if res.timedOut then return "timeout", kind == "cmd" end
	local outcome = classify(kind, res.exit, res.out)
	return outcome, outcome == "crash" or outcome == "raw_error"
end

--- Run one case under its deadline, measuring it and classifying the result.
---@param bin string
---@param case { kind: "cmd" | "eval" | "lua", args: string[], timeoutMs: integer }
---@param cwd string
---@return fuzz.RunResult
---@return string outcome
---@return number ms
local function runCase(bin, case, cwd)
	local start = ansi.now()
	local res = run(bin, case.args, { cwd = cwd, timeoutMs = case.timeoutMs })
	local ms = (ansi.now() - start) * 1000
	local outcome = evaluate(case.kind, res)
	return res, outcome, ms
end

return {
	runCase = runCase,
	evaluate = evaluate,
	OUTCOMES = OUTCOMES,
	csvField = csvField,
}
