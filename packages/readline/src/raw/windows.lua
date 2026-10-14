const ffi = require("ffi")

ffi.cdef([[
	typedef void*    HANDLE;
	typedef uint32_t DWORD;
	typedef int      BOOL;
	typedef uint16_t WORD;
	typedef int16_t  SHORT;
	typedef wchar_t  WCHAR;

	typedef struct {
		WORD X; WORD Y;
	} COORD;

	typedef struct {
		SHORT Left; SHORT Top; SHORT Right; SHORT Bottom;
	} SMALL_RECT;

	typedef struct {
		BOOL bKeyDown;
		WORD wRepeatCount;
		WORD wVirtualKeyCode;
		WORD wVirtualScanCode;
		union { WCHAR UnicodeChar; char AsciiChar; } uChar;
		DWORD dwControlKeyState;
	} KEY_EVENT_RECORD;

	typedef struct {
		WORD  EventType;
		union { KEY_EVENT_RECORD KeyEvent; } Event;
	} INPUT_RECORD;

	typedef struct {
		COORD      dwSize;
		COORD      dwCursorPosition;
		WORD       wAttributes;
		SMALL_RECT srWindow;
		COORD      dwMaximumWindowSize;
	} CONSOLE_SCREEN_BUFFER_INFO;

	HANDLE GetStdHandle(DWORD nStdHandle);
	BOOL   GetConsoleMode(HANDLE h, DWORD* mode);
	BOOL   SetConsoleMode(HANDLE h, DWORD mode);
	BOOL   ReadConsoleInputW(HANDLE h, INPUT_RECORD* buf, DWORD len, DWORD* read);
	BOOL   GetConsoleScreenBufferInfo(HANDLE h, CONSOLE_SCREEN_BUFFER_INFO* info);
]])

const kernel32 = ffi.load("kernel32")

const STD_INPUT_HANDLE       = ffi.cast("DWORD", -10)
const STD_OUTPUT_HANDLE      = ffi.cast("DWORD", -11)
const ENABLE_ECHO_INPUT      = 0x0004
const ENABLE_LINE_INPUT      = 0x0002
const ENABLE_PROCESSED_INPUT = 0x0001
const KEY_EVENT              = 0x0001

-- The console sends virtual key codes; this table maps them to the escapes the editor reads.
---@type table<integer, string>
const KEY = {
	[0x25] = "\x1b[D",   -- left
	[0x26] = "\x1b[A",   -- up
	[0x27] = "\x1b[C",   -- right
	[0x28] = "\x1b[B",   -- down
	[0x24] = "\x1b[H",   -- home
	[0x23] = "\x1b[F",   -- end
	[0x08] = "\x7f",     -- backspace
	[0x2E] = "\x1b[3~",  -- delete
	[0x0D] = "\r",       -- enter
}

-- Held, not made per call: readByte runs per keystroke and would garbage a fresh record.
local record = ffi.new("INPUT_RECORD[1]")
const read   = ffi.new("DWORD[1]")
const screen = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")

---@class readline.raw.windows
const readline = {}

local hIn, hOut, savedMode

function readline.enterRaw()
	hIn        = kernel32.GetStdHandle(STD_INPUT_HANDLE)
	hOut       = kernel32.GetStdHandle(STD_OUTPUT_HANDLE)
	const mode = ffi.new("DWORD[1]")
	kernel32.GetConsoleMode(hIn, mode)
	savedMode = mode[0]
	kernel32.SetConsoleMode(hIn, savedMode
		& ~(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT))
end

function readline.exitRaw()
	if savedMode and hIn then
		kernel32.SetConsoleMode(hIn, savedMode)
		savedMode = nil
	end
end

function readline.getCols()
	if kernel32.GetConsoleScreenBufferInfo(hOut, screen) ~= 0 then
		return screen.srWindow.Right - screen.srWindow.Left + 1
	end
	return 80
end

-- Returns a key descriptor: printable char, "up"/"down"/"left"/"right"/"home"/"end"/"backspace"/"delete"/"enter", or nil on EOF
function readline.readByte()
	while true do
		if kernel32.ReadConsoleInputW(hIn, record, 1, read) == 0 then return nil end
		const event = record[0].Event.KeyEvent
		if record[0].EventType == KEY_EVENT and event.bKeyDown ~= 0 and event.wVirtualKeyCode ~= 0 then
			const key = KEY[event.wVirtualKeyCode]
			if key then return key end
			const ch = event.uChar.AsciiChar
			if ch ~= 0 then return string.char(ch) end
		end
	end
end

return readline
