const ffi = require("ffi")

-- termios layout differs between Linux and macOS. Both blocks are read for their types, so the
-- fields below name a member of the struct rather than an offset into one.
if jit.os == "OSX" then
	ffi.cdef([[
		struct termios {
			unsigned long  c_iflag;
			unsigned long  c_oflag;
			unsigned long  c_cflag;
			unsigned long  c_lflag;
			uint8_t        c_cc[20];
			unsigned long  c_ispeed;
			unsigned long  c_ospeed;
		};
	]])
else
	ffi.cdef([[
		struct termios {
			uint32_t c_iflag;
			uint32_t c_oflag;
			uint32_t c_cflag;
			uint32_t c_lflag;
			uint8_t  c_line;
			uint8_t  c_cc[32];
			uint32_t c_ispeed;
			uint32_t c_ospeed;
		};
	]])
end

-- `read` is declared with the same prototype as the process package's, so re-declaring it is a
-- no-op where that already ran and keeps this module working on its own.
ffi.cdef([[
	int tcgetattr(int fd, struct termios *t);
	int tcsetattr(int fd, int action, const struct termios *t);
	int tcflush(int fd, int queue);
	struct winsize { uint16_t ws_row; uint16_t ws_col; uint16_t ws_xpixel; uint16_t ws_ypixel; };
	int ioctl(int fd, unsigned long req, ...);
	long read(int fd, void* buf, size_t count);
]])

const OSX = jit.os == "OSX"

-- The flags and control characters the two platforms do not agree on, in one place: the Linux bits
-- are <asm/termbits.h>, the macOS ones <sys/termios.h>, and clearing the Linux ECHOE/ECHOKE there
-- leaves the terminal canonical, so no keystroke arrives before Enter.
---@type table<string, integer>
const TC = OSX
	? { ICANON = 0x100, ISIG = 0x80, IXON = 0x200, IEXTEN = 0x400, VTIME = 17, VMIN = 16, TIOCGWINSZ = 0x40087468 }
	: { ICANON = 0x2, ISIG = 0x1, IXON = 0x400, IEXTEN = 0x8000, VTIME = 5, VMIN = 6, TIOCGWINSZ = 0x5413 }

local TCSANOW = 0
const ECHO    = 0x8
const ICRNL   = 0x100
const OPOST   = 0x1

-- Held rather than made per call: `readByte` runs once per keystroke, and a buffer made there is
-- garbage on every one of them. The two termios are filled by the calls that read the terminal, so
-- nothing has to be sized or copied by hand.
const saved   = ffi.new("struct termios")
const current = ffi.new("struct termios")
const size    = ffi.new("struct winsize")
local byte    = ffi.new("uint8_t[1]")
local inRaw   = false

const readline = {}

function readline.enterRaw()
	ffi.C.tcgetattr(0, saved)
	ffi.C.tcgetattr(0, current)
	current.c_iflag &= ~(TC.IXON | ICRNL)
	current.c_oflag &= ~OPOST
	current.c_lflag &= ~(ECHO | TC.ICANON | TC.ISIG | TC.IEXTEN)
	current.c_cc[TC.VMIN] = 1
	current.c_cc[TC.VTIME] = 0
	ffi.C.tcsetattr(0, TCSANOW, current)
	inRaw = true
end

function readline.exitRaw()
	if not inRaw then return end
	ffi.C.tcflush(0, 0) -- TCIFLUSH: drop what was typed and never read
	ffi.C.tcsetattr(0, TCSANOW, saved)
	inRaw = false
end

function readline.getCols()
	if ffi.C.ioctl(1, TC.TIOCGWINSZ, size) == 0 then return size.ws_col end
	return 80
end

function readline.readByte()
	const n = ffi.C.read(0, byte, 1)
	if n <= 0 then return nil end
	return string.char(byte[0])
end

return readline
