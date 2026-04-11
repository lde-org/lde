local ffi = require("ffi")

-- termios layout differs between Linux and macOS
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

ffi.cdef([[
	int tcgetattr(int fd, struct termios *t);
	int tcsetattr(int fd, int action, const struct termios *t);
	int tcflush(int fd, int queue);
	struct winsize { uint16_t ws_row; uint16_t ws_col; uint16_t ws_xpixel; uint16_t ws_ypixel; };
	int ioctl(int fd, unsigned long req, ...);
]])

local TCSANOW    = 0
local ECHO       = 0x8
local ICANON     = 0x2
local ISIG       = 0x1
local IXON       = 0x400
local IEXTEN     = jit.os == "OSX" and 0x400 or 0x8000
local ICRNL      = 0x100
local OPOST      = 0x1
-- TIOCGWINSZ: Linux=0x5413, macOS=0x40087468
local TIOCGWINSZ = jit.os == "OSX" and 0x40087468 or 0x5413
-- c_cc indices: Linux VTIME=5 VMIN=6, macOS VTIME=17 VMIN=16
local VTIME      = jit.os == "OSX" and 17 or 5
local VMIN       = jit.os == "OSX" and 16 or 6

local Termios    = ffi.typeof("struct termios")
local Winsize    = ffi.typeof("struct winsize")

---@class readline.raw.posix
local readline   = {}

local saved      = nil

function readline.enterRaw()
	local t = Termios()
	ffi.C.tcgetattr(0, t)
	saved = Termios()
	ffi.copy(saved, t, ffi.sizeof(t))

	t.c_iflag = bit.band(t.c_iflag, bit.bnot(bit.bor(IXON, ICRNL)))
	t.c_oflag = bit.band(t.c_oflag, bit.bnot(OPOST))
	t.c_lflag = bit.band(t.c_lflag, bit.bnot(bit.bor(ECHO, ICANON, ISIG, IEXTEN)))
	t.c_cc[VMIN]  = 1
	t.c_cc[VTIME] = 0
	ffi.C.tcsetattr(0, TCSANOW, t)
end

function readline.exitRaw()
	if saved then
		ffi.C.tcflush(0, 0) -- TCIFLUSH = 0, discard unread input
		ffi.C.tcsetattr(0, TCSANOW, saved)
		saved = nil
	end
end

---@return number cols
function readline.getCols()
	local ws = Winsize()
	if ffi.C.ioctl(1, TIOCGWINSZ, ws) == 0 then
		return tonumber(ws.ws_col)
	end
	return 80
end

---@return string? # byte, or nil on EOF
function readline.readByte()
	local buf = ffi.new("uint8_t[1]")
	local n = ffi.C.read(0, buf, 1)
	if n <= 0 then return nil end
	return string.char(buf[0])
end

return readline
