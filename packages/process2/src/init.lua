local isWindows = jit.os == "Windows"

---@class process2.raw
local raw = isWindows
	and require("process2.raw.windows")
	or require("process2.raw.posix")

---@alias process2.Stdio "pipe" | "inherit" | "null"

---@class process2.Options
---@field cwd string?
---@field env table<string, string>?
---@field stdin string?
---@field stdout process2.Stdio?
---@field stderr process2.Stdio?

---@class process2.Child
---@field pid number
---@field kill fun(self: process2.Child, force: boolean?)
---@field wait fun(self: process2.Child): number?, string?, string?
---@field poll fun(self: process2.Child): number?

---@class process2
local process2 = {}

if jit.os == "Windows" then
	process2.platform = "win32"
elseif jit.os == "Linux" then
	process2.platform = "linux"
elseif jit.os == "OSX" then
	process2.platform = "darwin"
else
	process2.platform = "unix"
end

local function readOut(r)
	if isWindows then
		local stdout = r.stdoutHandle and raw.readHandle(r.stdoutHandle) or nil
		local stderr = r.stderrHandle and raw.readHandle(r.stderrHandle) or nil
		return stdout, stderr
	else
		if r.stdoutFd and r.stderrFd then
			return raw.readFds(r.stdoutFd, r.stderrFd)
		end

		local stdout = r.stdoutFd and raw.readFd(r.stdoutFd) or nil
		local stderr = r.stderrFd and raw.readFd(r.stderrFd) or nil
		return stdout, stderr
	end
end

local function waitHandle(r)
	if isWindows then return raw.wait(r.handle) else return raw.wait(r.pid) end
end

local function pollHandle(r)
	if isWindows then return raw.poll(r.handle) else return raw.poll(r.pid) end
end

local function killHandle(r, force)
	if isWindows then raw.kill(r.handle) else raw.kill(r.pid, force) end
end

--- Spawn a process asynchronously. Returns a Child handle.
---@param name string
---@param args string[]?
---@param opts process2.Options?
---@return process2.Child?, string?
function process2.spawn(name, args, opts)
	opts = opts or {}
	local result, err = raw.spawn(name, args or {}, {
		cwd    = opts.cwd,
		env    = opts.env,
		stdin  = opts.stdin,
		stdout = opts.stdout or "null",
		stderr = opts.stderr or "null"
	})
	if not result then return nil, err end

	local r = result
	---@type process2.Child
	local child = { pid = result.pid }

	function child:kill(force) killHandle(r, force) end

	function child:wait()
		local stdout, stderr = readOut(r)
		local code = waitHandle(r)
		return code, stdout, stderr
	end

	function child:poll() return pollHandle(r) end

	return child
end

--- Execute a process and block until it exits.
---@param name string
---@param args string[]?
---@param opts process2.Options?
---@return number? exitCode
---@return string? stdout
---@return string? stderr
function process2.exec(name, args, opts)
	opts = opts or {}
	local result, err = raw.spawn(name, args or {}, {
		cwd    = opts.cwd,
		env    = opts.env,
		stdin  = opts.stdin,
		stdout = opts.stdout or "pipe",
		stderr = opts.stderr or "pipe"
	})
	if not result then return nil, nil, err end

	local stdout, stderr = readOut(result)
	local code = waitHandle(result)
	return code, stdout, stderr
end

return process2
