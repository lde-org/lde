local ffi = require("ffi")

ffi.cdef([[
	typedef void*    HANDLE;
	typedef uint32_t DWORD;
	typedef int      BOOL;
	typedef uint16_t WORD;
	typedef wchar_t  WCHAR;

	typedef struct {
		WORD X; WORD Y;
	} COORD;

	typedef struct {
		WORD wVirtualKeyCode;
		WORD wVirtualScanCode;
		union { WCHAR UnicodeChar; char AsciiChar; } uChar;
		DWORD dwControlKeyState;
	} KEY_EVENT_RECORD;

	typedef struct {
		WORD  EventType;
		union { KEY_EVENT_RECORD KeyEvent; } Event;
	} INPUT_RECORD;

	HANDLE GetStdHandle(DWORD nStdHandle);
	BOOL   GetConsoleMode(HANDLE h, DWORD* mode);
	BOOL   SetConsoleMode(HANDLE h, DWORD mode);
	BOOL   ReadConsoleInputW(HANDLE h, INPUT_RECORD* buf, DWORD len, DWORD* read);
	BOOL   GetConsoleScreenBufferInfo(HANDLE h, void* info);
]])

local kernel32               = ffi.load("kernel32")

local STD_INPUT_HANDLE       = ffi.cast("DWORD", -10)
local STD_OUTPUT_HANDLE      = ffi.cast("DWORD", -11)
local ENABLE_ECHO_INPUT      = 0x0004
local ENABLE_LINE_INPUT      = 0x0002
local ENABLE_PROCESSED_INPUT = 0x0001
local KEY_EVENT              = 0x0001
-- virtual key codes
local VK_LEFT                = 0x25
local VK_RIGHT               = 0x26 -- actually 0x27, see below
local VK_UP                  = 0x26
local VK_DOWN                = 0x28
local VK_HOME                = 0x24
local VK_END                 = 0x23
local VK_BACK                = 0x08
local VK_DELETE              = 0x2E
local VK_RETURN              = 0x0D

-- correct VK codes
VK_LEFT                      = 0x25
VK_UP                        = 0x26
VK_RIGHT                     = 0x27
VK_DOWN                      = 0x28

local DwordBox               = ffi.typeof("DWORD[1]")
local InputRecord            = ffi.typeof("INPUT_RECORD[1]")

---@class readline.raw.windows
local readline               = {}

local hIn, hOut
local savedMode              = nil

function readline.enterRaw()
	hIn        = kernel32.GetStdHandle(STD_INPUT_HANDLE)
	hOut       = kernel32.GetStdHandle(STD_OUTPUT_HANDLE)
	local mode = DwordBox()
	kernel32.GetConsoleMode(hIn, mode)
	savedMode = tonumber(mode[0])
	local newMode = bit.band(savedMode, bit.bnot(bit.bor(
		ENABLE_ECHO_INPUT, ENABLE_LINE_INPUT, ENABLE_PROCESSED_INPUT
	)))
	kernel32.SetConsoleMode(hIn, newMode)
end

function readline.exitRaw()
	if savedMode and hIn then
		kernel32.SetConsoleMode(hIn, savedMode)
		savedMode = nil
	end
end

function readline.getCols()
	-- CONSOLE_SCREEN_BUFFER_INFO is 22 bytes
	local info = ffi.new("uint8_t[22]")
	if kernel32.GetConsoleScreenBufferInfo(hOut, info) ~= 0 then
		-- dwSize is first field: COORD (2x WORD), srWindow at offset 10: LEFT,TOP,RIGHT,BOTTOM (4x SHORT)
		local right = ffi.cast("int16_t*", info + 14)[0]
		local left  = ffi.cast("int16_t*", info + 10)[0]
		return tonumber(right - left + 1)
	end
	return 80
end

-- Returns a key descriptor string: printable char, or one of:
-- "up","down","left","right","home","end","backspace","delete","enter", nil on EOF
function readline.readByte()
	local rec   = InputRecord()
	local nread = DwordBox()
	while true do
		if kernel32.ReadConsoleInputW(hIn, rec, 1, nread) == 0 then return nil end
		local r = rec[0]
		if r.EventType == KEY_EVENT and r.Event.KeyEvent.wVirtualKeyCode ~= 0 then
			local vk = tonumber(r.Event.KeyEvent.wVirtualKeyCode)
			local ch = r.Event.KeyEvent.uChar.AsciiChar
			if vk == VK_LEFT then
				return "\x1b[D"
			elseif vk == VK_RIGHT then
				return "\x1b[C"
			elseif vk == VK_UP then
				return "\x1b[A"
			elseif vk == VK_DOWN then
				return "\x1b[B"
			elseif vk == VK_HOME then
				return "\x1b[H"
			elseif vk == VK_END then
				return "\x1b[F"
			elseif vk == VK_BACK then
				return "\x7f"
			elseif vk == VK_DELETE then
				return "\x1b[3~"
			elseif vk == VK_RETURN then
				return "\r"
			elseif ch ~= "\0" then
				return ch
			end
		end
	end
end

return readline
