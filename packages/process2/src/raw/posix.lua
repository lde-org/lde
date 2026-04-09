local ffi = require("ffi")
local sb  = require("string.buffer")

ffi.cdef([[
	typedef int pid_t;
	pid_t fork(void);
	int   execvp(const char* file, const char* const argv[]);
	pid_t waitpid(pid_t pid, int* status, int options);
	int   kill(pid_t pid, int sig);
	int   pipe(int pipefd[2]);
	long  read(int fd, void* buf, size_t count);
	long  write(int fd, const void* buf, size_t count);
	int   close(int fd);
	int   dup2(int oldfd, int newfd);
	int   open(const char* path, int flags, ...);
	int   setenv(const char* name, const char* value, int overwrite);
	int   chdir(const char* path);
	void  _exit(int status);
	struct pollfd { int fd; short events; short revents; };
	int   poll(struct pollfd* fds, unsigned long nfds, int timeout);
]])

local WNOHANG = 1
local SIGTERM = 15
local SIGKILL = 9
local O_WRONLY = 1
local POLLIN   = 1
local POLLHUP  = 16

---@diagnostic disable: assign-type-mismatch # Ignore incessant ffi type cast annoyance

---@class process2.ffi.IntBox: ffi.cdata*
---@field [0] number

---@type fun(): process2.ffi.IntBox
local IntBox = ffi.typeof("int[1]")

---@class process2.ffi.PipeFds: ffi.cdata*
---@field [0] number
---@field [1] number

---@type fun(): process2.ffi.PipeFds
local PipeFds = ffi.typeof("int[2]")

---@type fun(size: number): ffi.cdata*
local PollFds = ffi.typeof("struct pollfd[?]")

---@class process2.ffi.Argv: ffi.cdata*
---@field [0] string?

---@type fun(size: number): process2.ffi.Argv
local Argv = ffi.typeof("const char*[?]")

---@class process2.raw
local M = {}

---@param status number
---@return number?
local function decodeExit(status)
	if bit.band(status, 0x7f) == 0 then
		return bit.rshift(bit.band(status, 0xff00), 8)
	end
	return nil
end

---@param name string
---@param args string[]
---@return process2.ffi.Argv
local function makeArgv(name, args)
	local argv = Argv(#args + 2)
	argv[0] = name
	for i, a in ipairs(args) do argv[i] = a end
	argv[#args + 1] = nil
	return argv
end

--- Spawn a child process.
---@param name string
---@param args string[]
---@param opts { cwd: string?, env: table<string,string>?, stdin: string?, stdout: "pipe"|"inherit"|"null"?, stderr: "pipe"|"inherit"|"null"? }?
---@return { pid: number, stdoutFd: number?, stderrFd: number? }?, string?
function M.spawn(name, args, opts)
	opts              = opts or {}
	local stdoutMode  = opts.stdout or "pipe"
	local stderrMode  = opts.stderr or "pipe"
	local hasStdin    = opts.stdin ~= nil

	local pIn         = PipeFds()
	local pOut        = PipeFds()
	local pErr        = PipeFds()

	if hasStdin and ffi.C.pipe(pIn) ~= 0 then return nil, "pipe() failed" end
	if stdoutMode == "pipe" and ffi.C.pipe(pOut) ~= 0 then return nil, "pipe() failed" end
	if stderrMode == "pipe" and ffi.C.pipe(pErr) ~= 0 then return nil, "pipe() failed" end

	local pid = ffi.C.fork()
	if pid < 0 then return nil, "fork() failed" end

	if pid == 0 then
		if hasStdin then
			ffi.C.dup2(pIn[0], 0); ffi.C.close(pIn[0]); ffi.C.close(pIn[1])
		end
		if stdoutMode == "pipe" then
			ffi.C.dup2(pOut[1], 1); ffi.C.close(pOut[0]); ffi.C.close(pOut[1])
		elseif stdoutMode == "null" then
			local fd = ffi.C.open("/dev/null", O_WRONLY); ffi.C.dup2(fd, 1); ffi.C.close(fd)
		end
		if stderrMode == "pipe" then
			ffi.C.dup2(pErr[1], 2); ffi.C.close(pErr[0]); ffi.C.close(pErr[1])
		elseif stderrMode == "null" then
			local fd = ffi.C.open("/dev/null", O_WRONLY); ffi.C.dup2(fd, 2); ffi.C.close(fd)
		end
		if opts.cwd then ffi.C.chdir(opts.cwd) end
		if opts.env then for k, v in pairs(opts.env) do ffi.C.setenv(k, v, 1) end end
		ffi.C.execvp(name, makeArgv(name, args))
		ffi.C._exit(1)
	end

	if hasStdin then ffi.C.close(pIn[0]) end
	if stdoutMode == "pipe" then ffi.C.close(pOut[1]) end
	if stderrMode == "pipe" then ffi.C.close(pErr[1]) end

	if hasStdin then
		ffi.C.write(pIn[1], opts.stdin, #opts.stdin)
		ffi.C.close(pIn[1])
	end

	return {
		pid      = tonumber(pid),
		stdoutFd = stdoutMode == "pipe" and tonumber(pOut[0]) or nil,
		stderrFd = stderrMode == "pipe" and tonumber(pErr[0]) or nil
	}
end

---@param fd number
---@return string
function M.readFd(fd)
	local out = sb.new()
	while true do
		local ptr, len = out:reserve(4096)
		local n = ffi.C.read(fd, ptr, len)
		if n > 0 then out:commit(n)
		else out:commit(0); break
		end
	end
	ffi.C.close(fd)
	return out:tostring()
end

--- Drain two fds concurrently using poll() to avoid deadlock.
---@param outFd number
---@param errFd number
---@return string, string
function M.readFds(outFd, errFd)
	local outBuf, errBuf = sb.new(), sb.new()
	local fds = PollFds(2)
	local outDone, errDone = false, false
	while not outDone or not errDone do
		fds[0].fd = outDone and -1 or outFd
		fds[0].events = POLLIN
		fds[1].fd = errDone and -1 or errFd
		fds[1].events = POLLIN
		ffi.C.poll(fds, 2, -1)
		if not outDone then
			if bit.band(fds[0].revents, POLLIN) ~= 0 then
				local ptr, len = outBuf:reserve(4096)
				local n = ffi.C.read(outFd, ptr, len)
				if n > 0 then outBuf:commit(n)
				else outBuf:commit(0); outDone = true
				end
			elseif fds[0].revents ~= 0 then
				outDone = true
			end
		end
		if not errDone then
			if bit.band(fds[1].revents, POLLIN) ~= 0 then
				local ptr, len = errBuf:reserve(4096)
				local n = ffi.C.read(errFd, ptr, len)
				if n > 0 then errBuf:commit(n)
				else errBuf:commit(0); errDone = true
				end
			elseif fds[1].revents ~= 0 then
				errDone = true
			end
		end
	end
	ffi.C.close(outFd)
	ffi.C.close(errFd)
	return outBuf:tostring(), errBuf:tostring()
end

---@param pid number
---@return number?
function M.wait(pid)
	local st = IntBox()
	ffi.C.waitpid(pid, st, 0)
	return decodeExit(st[0])
end

---@param pid number
---@return number?
function M.poll(pid)
	local st = IntBox()
	if ffi.C.waitpid(pid, st, WNOHANG) == 0 then return nil end
	return decodeExit(st[0])
end

---@param pid number
---@param force boolean?
function M.kill(pid, force)
	ffi.C.kill(pid, force and SIGKILL or SIGTERM)
end

return M
