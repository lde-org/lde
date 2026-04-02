local ffi    = require("ffi")
local buffer = require("string.buffer")

ffi.cdef([[
	typedef void*    HANDLE;
	typedef uint32_t DWORD;
	typedef int      BOOL;
	typedef uint16_t WORD;
	typedef char*    LPSTR;

	typedef struct {
		DWORD  nLength;
		void*  lpSecurityDescriptor;
		BOOL   bInheritHandle;
	} SECURITY_ATTRIBUTES;

	typedef struct {
		DWORD  cb;
		LPSTR  lpReserved;
		LPSTR  lpDesktop;
		LPSTR  lpTitle;
		DWORD  dwX, dwY, dwXSize, dwYSize;
		DWORD  dwXCountChars, dwYCountChars;
		DWORD  dwFillAttribute;
		DWORD  dwFlags;
		WORD   wShowWindow;
		WORD   cbReserved2;
		void*  lpReserved2;
		HANDLE hStdInput;
		HANDLE hStdOutput;
		HANDLE hStdError;
	} STARTUPINFOA;

	typedef struct {
		HANDLE hProcess;
		HANDLE hThread;
		DWORD  dwProcessId;
		DWORD  dwThreadId;
	} PROCESS_INFORMATION;

	BOOL CreateProcessA(
		const char* lpApplicationName,
		char*       lpCommandLine,
		void*       lpProcessAttributes,
		void*       lpThreadAttributes,
		BOOL        bInheritHandles,
		DWORD       dwCreationFlags,
		void*       lpEnvironment,
		const char* lpCurrentDirectory,
		STARTUPINFOA*        lpStartupInfo,
		PROCESS_INFORMATION* lpProcessInformation
	);

	BOOL   CreatePipe(HANDLE* hReadPipe, HANDLE* hWritePipe, SECURITY_ATTRIBUTES* lpPipeAttributes, DWORD nSize);
	BOOL   SetHandleInformation(HANDLE hObject, DWORD dwMask, DWORD dwFlags);
	BOOL   ReadFile(HANDLE hFile, void* lpBuffer, DWORD nNumberOfBytesToRead, DWORD* lpNumberOfBytesRead, void* lpOverlapped);
	BOOL   WriteFile(HANDLE hFile, const void* lpBuffer, DWORD nNumberOfBytesToWrite, DWORD* lpNumberOfBytesWritten, void* lpOverlapped);
	DWORD  WaitForSingleObject(HANDLE hHandle, DWORD dwMilliseconds);
	BOOL   GetExitCodeProcess(HANDLE hProcess, DWORD* lpExitCode);
	BOOL   TerminateProcess(HANDLE hProcess, DWORD uExitCode);
	BOOL   CloseHandle(HANDLE hObject);
	HANDLE GetStdHandle(DWORD nStdHandle);
	HANDLE CreateFileA(const char*, DWORD, DWORD, void*, DWORD, DWORD, HANDLE);
]])

local kernel32               = ffi.load("kernel32")

local STARTF_USESTDHANDLES   = 0x00000100
local HANDLE_FLAG_INHERIT    = 0x00000001
local INFINITE               = 0xFFFFFFFF
local STILL_ACTIVE           = 259
local CREATE_NO_WINDOW       = 0x08000000
local STD_INPUT_HANDLE       = ffi.cast("DWORD", -10)
local STD_OUTPUT_HANDLE      = ffi.cast("DWORD", -11)
local STD_ERROR_HANDLE       = ffi.cast("DWORD", -12)
local INVALID_HANDLE_VALUE   = ffi.cast("HANDLE", -1)
local GENERIC_READ           = 0x80000000
local GENERIC_WRITE          = 0x40000000
local OPEN_EXISTING          = 3
local FILE_ATTRIBUTE_NORMAL  = 0x80

---@class process2.ffi.SecurityAttributes: ffi.cdata*
---@field nLength number
---@field lpSecurityDescriptor ffi.cdata*
---@field bInheritHandle number

---@diagnostic disable: assign-type-mismatch # Ignore incessant ffi type cast annoyance

---@type fun(): process2.ffi.SecurityAttributes
local SecurityAttributes     = ffi.typeof("SECURITY_ATTRIBUTES")

---@type number
local SecurityAttributesSize = ffi.sizeof("SECURITY_ATTRIBUTES")

---@class process2.ffi.StartupInfoA: ffi.cdata*
---@field cb number
---@field dwFlags number
---@field hStdInput ffi.cdata*
---@field hStdOutput ffi.cdata*
---@field hStdError ffi.cdata*

---@type fun(): process2.ffi.StartupInfoA
local StartupInfoA           = ffi.typeof("STARTUPINFOA")

---@type number
local StartupInfoASize       = ffi.sizeof("STARTUPINFOA")

---@class process2.ffi.ProcessInformation: ffi.cdata*
---@field hProcess ffi.cdata*
---@field hThread ffi.cdata*
---@field dwProcessId number
---@field dwThreadId number

---@type fun(): process2.ffi.ProcessInformation
local ProcessInformation     = ffi.typeof("PROCESS_INFORMATION")

---@class process2.ffi.HandleBox: ffi.cdata*
---@field [0] ffi.cdata*

---@type fun(): process2.ffi.HandleBox
local HandleBox              = ffi.typeof("HANDLE[1]")

---@class process2.ffi.DwordBox: ffi.cdata*
---@field [0] number

---@type fun(): process2.ffi.DwordBox
local DwordBox               = ffi.typeof("DWORD[1]")

---@class process2.ffi.CharBuf: ffi.cdata*

---@type fun(size: number, s: string?): process2.ffi.CharBuf
local CharBuf                = ffi.typeof("char[?]")

---@class process2.raw
local M                      = {}

---@param s string
---@return string
local function escapeArg(s)
	if not s:find('[ \t\n\v"\\]') and s ~= "" then return s end
	local out, i = { '"' }, 1
	while i <= #s do
		local c = s:sub(i, i)
		if c == "\\" then
			local j = i
			while j <= #s and s:sub(j, j) == "\\" do j = j + 1 end
			local nbs = j - i
			if j > #s or s:sub(j, j) == '"' then nbs = nbs * 2 end
			out[#out + 1] = string.rep("\\", nbs)
			i = j
		elseif c == '"' then
			out[#out + 1] = '\\"'; i = i + 1
		else
			out[#out + 1] = c; i = i + 1
		end
	end
	out[#out + 1] = '"'
	return table.concat(out)
end

---@param name string
---@param args string[]
---@return string
local function buildCmdLine(name, args)
	local parts = { escapeArg(name) }
	for _, a in ipairs(args) do parts[#parts + 1] = escapeArg(a) end
	return table.concat(parts, " ")
end

---@param inheritRead boolean
---@param inheritWrite boolean
---@return ffi.cdata*?, ffi.cdata*?
local function makePipe(inheritRead, inheritWrite)
	local sa = SecurityAttributes()
	sa.nLength = SecurityAttributesSize
	sa.bInheritHandle = 1

	local r, w = HandleBox(), HandleBox()
	if kernel32.CreatePipe(r, w, sa, 0) == 0 then return nil, nil end
	if not inheritRead then kernel32.SetHandleInformation(r[0], HANDLE_FLAG_INHERIT, 0) end
	if not inheritWrite then kernel32.SetHandleInformation(w[0], HANDLE_FLAG_INHERIT, 0) end

	return r[0], w[0]
end

---@param write boolean
---@return ffi.cdata*?
local function nullHandle(write)
	local h = kernel32.CreateFileA("nul", write and GENERIC_WRITE or GENERIC_READ, 0, nil, OPEN_EXISTING,
		FILE_ATTRIBUTE_NORMAL, nil)
	return h ~= INVALID_HANDLE_VALUE and h or nil
end

---@param env table<string, string>
---@return string
local function buildEnvBlock(env)
	local buf = buffer.new()
	for k, v in pairs(env) do buf:put(k, "=", v, "\0") end
	buf:put("\0")
	return buf:tostring()
end

---@param name string
---@param args string[]
---@param opts { cwd: string?, env: table<string,string>?, stdin: string?, stdout: "pipe"|"inherit"|"null"?, stderr: "pipe"|"inherit"|"null"? }?
---@return { handle: ffi.cdata*, pid: number, stdoutHandle: ffi.cdata*?, stderrHandle: ffi.cdata*? }?, string?
function M.spawn(name, args, opts)
	opts             = opts or {}
	local stdoutMode = opts.stdout or "pipe"
	local stderrMode = opts.stderr or "pipe"
	local hasStdin   = opts.stdin ~= nil

	local si         = StartupInfoA()
	si.cb            = StartupInfoASize
	si.dwFlags       = STARTF_USESTDHANDLES

	local stdinR, stdinW, stdoutR, stdoutW, stderrR, stderrW
	local nullOut, nullErr

	if hasStdin then
		stdinR, stdinW = makePipe(true, false)
		if not stdinR then return nil, "CreatePipe failed" end
		si.hStdInput = stdinR
	else
		si.hStdInput = kernel32.GetStdHandle(STD_INPUT_HANDLE)
	end

	if stdoutMode == "pipe" then
		stdoutR, stdoutW = makePipe(false, true)
		if not stdoutR then return nil, "CreatePipe failed" end
		si.hStdOutput = stdoutW
	elseif stdoutMode == "null" then
		nullOut = nullHandle(true)
		si.hStdOutput = nullOut
	else
		si.hStdOutput = kernel32.GetStdHandle(STD_OUTPUT_HANDLE)
	end

	if stderrMode == "pipe" then
		stderrR, stderrW = makePipe(false, true)
		if not stderrR then return nil, "CreatePipe failed" end
		si.hStdError = stderrW
	elseif stderrMode == "null" then
		nullErr = nullHandle(true)
		si.hStdError = nullErr
	else
		si.hStdError = kernel32.GetStdHandle(STD_ERROR_HANDLE)
	end

	local cmdStr   = buildCmdLine(name, args)
	local cmdLine  = CharBuf(#cmdStr + 1, cmdStr)
	local envBlock = opts.env and buildEnvBlock(opts.env) or nil
	local pi       = ProcessInformation()

	local ok       = kernel32.CreateProcessA(
		nil, cmdLine, nil, nil, 1,
		CREATE_NO_WINDOW, envBlock, opts.cwd or nil, si, pi
	)

	if stdinR then kernel32.CloseHandle(stdinR) end
	if stdoutW then kernel32.CloseHandle(stdoutW) end
	if stderrW then kernel32.CloseHandle(stderrW) end
	if nullOut then kernel32.CloseHandle(nullOut) end
	if nullErr then kernel32.CloseHandle(nullErr) end

	if ok == 0 then return nil, "CreateProcess failed" end

	kernel32.CloseHandle(pi.hThread)

	if hasStdin then
		local written = DwordBox()
		kernel32.WriteFile(stdinW, opts.stdin, #opts.stdin, written, nil)
		kernel32.CloseHandle(stdinW)
	end

	return {
		handle       = pi.hProcess,
		pid          = tonumber(pi.dwProcessId),
		stdoutHandle = stdoutR,
		stderrHandle = stderrR
	}
end

---@param handle ffi.cdata*
---@return string
function M.readHandle(handle)
	local buf    = CharBuf(4096)
	local read   = DwordBox()
	local chunks = {}
	while kernel32.ReadFile(handle, buf, 4096, read, nil) ~= 0 and read[0] > 0 do
		chunks[#chunks + 1] = ffi.string(buf, read[0])
	end
	kernel32.CloseHandle(handle)
	return table.concat(chunks)
end

---@param handle ffi.cdata*
---@return number?
function M.wait(handle)
	kernel32.WaitForSingleObject(handle, INFINITE)
	local code = DwordBox()
	kernel32.GetExitCodeProcess(handle, code)
	kernel32.CloseHandle(handle)
	return tonumber(code[0])
end

---@param handle ffi.cdata*
---@return number?
function M.poll(handle)
	local code = DwordBox()
	kernel32.GetExitCodeProcess(handle, code)
	if tonumber(code[0]) == STILL_ACTIVE then return nil end
	kernel32.CloseHandle(handle)
	return tonumber(code[0])
end

---@param handle ffi.cdata*
function M.kill(handle)
	kernel32.TerminateProcess(handle, 1)
end

return M
