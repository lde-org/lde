const ffi = require("ffi")

-- Typed views over the ffi.cdef structs below (the LS can't see cdef fields).
---@class ansi.ffi.LARGE_INTEGER: ffi.cdata*
---@field val number
---@class ansi.ffi.timespec: ffi.cdata*
---@field tv_sec number
---@field tv_nsec number

-- Both probes are writable so tests can pin either path: live rendering is
-- otherwise terminal-dependent. isTTY tracks stdout (the payload stream),
-- isStderrTTY tracks stderr (where install progress draws).
local isStderrTTY = true
local now

-- Declared before the probes below, which record their results on it.
const ansi = {}
ansi.isTTY = true

do
	if ffi.os == "Windows" then
		pcall(ffi.cdef, "int _isatty(int fd);")
		local ok, result = pcall(|| -> ffi.C._isatty(1) ~= 0)
		if ok then ansi.isTTY = result end
		local okErr, resultErr = pcall(|| -> ffi.C._isatty(2) ~= 0)
		if okErr then isStderrTTY = resultErr end

		if ansi.isTTY or isStderrTTY then
			-- Legacy Windows consoles (conhost) ignore ANSI escapes unless VT
			-- processing is enabled on the handle being written to. Without this,
			-- progress redraws (\x1b[2K\r) print the escape bytes literally and
			-- never clear the previous line, so each update appends a new entry.
			pcall(ffi.cdef, [[
				typedef void* HANDLE;
				typedef uint32_t DWORD;
				typedef int BOOL;
				HANDLE GetStdHandle(DWORD nStdHandle);
				BOOL GetConsoleMode(HANDLE hConsoleHandle, DWORD *lpMode);
				BOOL SetConsoleMode(HANDLE hConsoleHandle, DWORD dwMode);
			]])
			---@param nStdHandle number # STD_OUTPUT_HANDLE (-11) or STD_ERROR_HANDLE (-12)
			local function enableVirtualTerminal(nStdHandle)
				pcall(function()
					const kernel32 = ffi.load("kernel32")
					const ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
					local hOut = kernel32.GetStdHandle(ffi.cast("DWORD", nStdHandle))
					const mode = ffi.new("DWORD[1]")
					-- GetConsoleMode fails when the handle isn't a console (redirected),
					-- in which case there's nothing to enable.
					if kernel32.GetConsoleMode(hOut, mode) ~= 0 then
						kernel32.SetConsoleMode(hOut, mode[0] | ENABLE_VIRTUAL_TERMINAL_PROCESSING)
					end
				end)
			end
			if ansi.isTTY then enableVirtualTerminal(-11) end
			if isStderrTTY then enableVirtualTerminal(-12) end
		end

		pcall(ffi.cdef, [[
			typedef union { struct { uint32_t lo, hi; }; uint64_t val; } LARGE_INTEGER;
			int QueryPerformanceCounter(LARGE_INTEGER *lpPerformanceCount);
			int QueryPerformanceFrequency(LARGE_INTEGER *lpFrequency);
		]])
		const freqOk, freq = pcall(function()
			local f = ffi.new("LARGE_INTEGER")
			ffi.C.QueryPerformanceFrequency(f)
			return tonumber(f --[[@as ansi.ffi.LARGE_INTEGER]].val)
		end)
		if freqOk then
			now = function()
				local t = ffi.new("LARGE_INTEGER")
				ffi.C.QueryPerformanceCounter(t)
				return tonumber(t --[[@as ansi.ffi.LARGE_INTEGER]].val) / freq
			end
		end
	else
		pcall(ffi.cdef, "int isatty(int fd);")
		local ok, result = pcall(|| -> ffi.C.isatty(1) ~= 0)
		if ok then ansi.isTTY = result end
		local okErr, resultErr = pcall(|| -> ffi.C.isatty(2) ~= 0)
		if okErr then isStderrTTY = resultErr end

		pcall(ffi.cdef, "typedef struct { long tv_sec; long tv_nsec; } timespec;")
		pcall(ffi.cdef, "int clock_gettime(int clk_id, timespec *tp);")
		-- Clock ids are per-OS, and getting one wrong here is silent: FreeBSD's
		-- id 1 is CLOCK_VIRTUAL (process CPU time), which every sleep and I/O
		-- wait leaves untouched, so elapsed times would read ~0 while the id
		-- check below still passes. Linux's CLOCK_MONOTONIC is 1, Darwin's 6,
		-- FreeBSD's (and DragonFly's) 4. LuaJIT reports every BSD as "BSD".
		local CLOCK_MONOTONIC = ffi.os == "OSX" and 6
			or ffi.os == "BSD" and 4
			or 1
		const clockOk = pcall(function()
			local t = ffi.new("timespec")
			-- Verify the clock id actually works (returns 0), not just that the
			-- call doesn't crash: a wrong id would silently zero the struct.
			return ffi.C.clock_gettime(CLOCK_MONOTONIC, t) == 0
		end)
		if clockOk then
			now = function()
				local t = ffi.new("timespec")
				ffi.C.clock_gettime(CLOCK_MONOTONIC, t)
				const ts = t --[[@as ansi.ffi.timespec]]
				return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) * 1e-9
			end
		end
	end
	if not now then now = os.clock end
end

-- Registered before ansi.progress is required (below) so its require("ansi")
-- resolves to this table instead of re-entering the loader.
package.loaded[(...)] = ansi

-- When true, ansi.progress() returns a silent handle. The test runner sets it
-- while installing dependencies so compact install bars and one-off downloads
-- (e.g. the LuaJIT tree) don't interleave flush-left with the indented test
-- results. Distinct from lde.isQuiet, which suppresses the install progress
-- line at its call site.
ansi.isQuiet = false

-- Whether the progress stream (stderr) is a terminal. Live bars redraw with \r
-- and erase escapes, which only make sense on one, so a redirected stream gets
-- the final line alone. Writable so tests can pin the non-TTY path: rendering
-- is otherwise terminal-dependent.
ansi.isStderrTTY = isStderrTTY

---@alias ansi.Color
--- | "reset"
--- | "red"
--- | "green"
--- | "yellow"
--- | "orange"
--- | "blue"
--- | "magenta"
--- | "cyan"
--- | "white"
--- | "gray"
--- | "bold"
--- | "underline"
--- | "bg_red"
--- | "bg_green"
--- | "bg_yellow"
--- | "bg_blue"
--- | "bg_magenta"
--- | "bg_cyan"
--- | "bg_white"
--- | "bg_gray"

---@type table<ansi.Color, string>
const colors = {
	reset = "\27[0m",
	red = "\27[31m",
	green = "\27[32m",
	yellow = "\27[33m",
	orange = "\27[38;5;208m",
	blue = "\27[34m",
	magenta = "\27[35m",
	cyan = "\27[36m",
	white = "\27[37m",
	gray = "\27[90m",
	bold = "\27[1m",
	underline = "\27[4m",
	bg_red = "\27[41m",
	bg_green = "\27[42m",
	bg_yellow = "\27[43m",
	bg_blue = "\27[44m",
	bg_magenta = "\27[45m",
	bg_cyan = "\27[46m",
	bg_white = "\27[47m",
	bg_gray = "\27[100m"
}

-- Colors are emitted when stdout is a terminal that supports them, or when
-- a CI log viewer renders ANSI without a tty (GitHub Actions, GitLab CI).
-- Windows consoles don't set TERM; their VT mode was enabled above.
local colorEnabled = ansi.isTTY
if colorEnabled and ffi.os ~= "Windows" then
	local term = os.getenv("TERM")
	colorEnabled = term ~= nil and term ~= "dumb"
end
if not colorEnabled and (os.getenv("GITHUB_ACTIONS") == "true" or os.getenv("GITLAB_CI") == "true") then
	colorEnabled = true
end

const noColor = os.getenv("NO_COLOR")
if noColor and noColor ~= "0" then
	colorEnabled = false
end

const forceColor = os.getenv("CLICOLOR_FORCE")
if forceColor and forceColor ~= "0" then
	colorEnabled = true
end

if not colorEnabled then
	for k in pairs(colors) do colors[k] = "" end
end

--- Whether this process emits colors. Callers that pipe a child's output and
--- re-emit it to their own terminal need it: the child sees a pipe, so it would
--- drop every escape unless the decision is carried across (CLICOLOR_FORCE).
ansi.hasColor = colorEnabled

---@param name ansi.Color
---@param s string
function ansi.colorize(name, s)
	return colors[name] .. s .. colors.reset
end

---@param f string
---@param ... any
function ansi.format(f, ...)
	return string.format(string.gsub(f, "{([^}]+)}", colors), ...) .. colors.reset
end

---@param f string
---@param ... any
function ansi.printf(f, ...)
	print(ansi.format(f, ...))
end

-- ANSI escape helpers
const ESC = "\27["

-- Terminal width in columns. Used by ansi.progress to clear live lines that
-- wrapped to multiple physical rows (a long label/bar on a narrow terminal);
-- `\x1b[2K` alone only clears the current row and leaves the wrapped residue.
-- Queried once via ioctl(TIOCGWINSZ) / GetConsoleScreenBufferInfo; defaults to 80.
---@class ansi.ffi.COORD: ffi.cdata*
---@field x number
---@field y number
---@class ansi.ffi.ConsoleScreenBufferInfo: ffi.cdata*
---@field size ansi.ffi.COORD
---@type integer
local columns = 80
do
	if ffi.os == "Windows" then
		pcall(ffi.cdef, [[
			typedef struct { short x, y; } COORD;
			typedef struct { short left, top, right, bottom; } SMALL_RECT;
			typedef struct { COORD size; COORD cursorPosition; short attributes; SMALL_RECT window; COORD maximumWindowSize; } CONSOLE_SCREEN_BUFFER_INFO;
			int GetConsoleScreenBufferInfo(void* hConsoleOutput, CONSOLE_SCREEN_BUFFER_INFO* info);
		]])
		pcall(function()
			local info = ffi.new("CONSOLE_SCREEN_BUFFER_INFO") --[[@as ansi.ffi.ConsoleScreenBufferInfo]]
			local hOut = ffi.C.GetStdHandle(ffi.cast("DWORD", -11))
			if ffi.C.GetConsoleScreenBufferInfo(hOut, info) ~= 0 then
				columns = math.floor(tonumber(info.size.x) or 80)
			end
		end)
	else
		-- ioctl may be re-cdef'd freely; `struct winsize` may NOT (readline
		-- defines it too, and LuaJIT rejects struct redefinition), so read the
		-- size into an anonymous uint16_t[4] instead of a named struct.
		pcall(ffi.cdef, "int ioctl(int fd, unsigned long request, void* argp);")
		pcall(function()
			-- TIOCGWINSZ: Linux/Android = 0x5413, macOS/BSD = 0x40087468.
			local TIOCGWINSZ = (jit.os == "OSX" or jit.os == "BSD") ? 0x40087468 : 0x5413
			const ws = ffi.new("uint16_t[4]") -- ws_row, ws_col, ws_xpixel, ws_ypixel
			if ffi.C.ioctl(1, TIOCGWINSZ, ws) == 0 and tonumber(ws[1]) > 0 then
				columns = math.floor(tonumber(ws[1]) or 80)
			end
		end)
	end
	if columns < 20 then columns = 80 end
end


-- Clear the visible screen and home the cursor, preserving scrollback
-- (bun-style fresh screen per re-run). TTY-only: the escape bytes would
-- corrupt redirected output.
function ansi.clearScreen()
	if not ansi.isTTY then return end
	io.write(ESC .. "2J" .. ESC .. "H")
	io.flush()
end

-- Monotonic wall-clock timestamp in seconds (Windows QPC / clock_gettime).
---@return number
function ansi.now()
	return now()
end

-- ─── Notice prefixes ─────────────────────────────────────────────────────
-- Consistent `label:` prefixes for diagnostics (colored label, gray colon).
-- Callers pass a format string plus args, exactly like ansi.eprintf.

--- Like ansi.printf, but for diagnostics. stdout carries the command's data —
--- the program output of `lde run`/`lde x <tool>`, a completion script, a
--- `--json` report — and callers pipe or `eval` it, so anything that isn't that
--- data goes to stderr.
---@param f string
---@param ... any
function ansi.eprintf(f, ...)
	io.stderr:write(ansi.format(f, ...) .. "\n")
end

---@param msg string
---@param ... any
function ansi.error(msg, ...)
	ansi.eprintf("{red}error{gray}:{reset} " .. msg, ...)
end

---@param msg string
---@param ... any
function ansi.warning(msg, ...)
	ansi.eprintf("{yellow}warning{gray}:{reset} " .. msg, ...)
end

---@param msg string
---@param ... any
function ansi.note(msg, ...)
	ansi.eprintf("{blue}note{gray}:{reset} " .. msg, ...)
end

---@param msg string
---@param ... any
function ansi.tip(msg, ...)
	ansi.eprintf("{green}tip{gray}:{reset} " .. msg, ...)
end

-- Shared with the ansi.progress submodule, which requires this module back
-- for colour codes and terminal geometry; not part of the public API.
ansi._core = {
	colors  = colors,
	escape  = ESC,
	columns = columns,
	isTTY   = ansi.isTTY,
	now     = now,
}

-- Drop any cached copy first: re-requiring ansi (which tests do to re-run
-- colour/emoji detection) must also re-run ansi.progress's emoji check.
package.loaded["ansi.progress"] = nil
const progress = require("ansi.progress")
ansi.progress         = progress.progress
ansi.installProgress  = progress.installProgress
ansi.formatBytes      = progress.formatBytes
ansi.formatElapsed    = progress.formatElapsed
ansi.supportsEmoji    = progress.supportsEmoji
ansi.downloadProgress = progress.downloadProgress

return ansi
