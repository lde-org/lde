local ffi = require("ffi")

-- Typed views over the ffi.cdef structs below (the LS can't see cdef fields).
---@class ansi.ffi.LARGE_INTEGER: ffi.cdata*
---@field val number
---@class ansi.ffi.timespec: ffi.cdata*
---@field tv_sec number
---@field tv_nsec number

local isTTY = true
local now
do
	if ffi.os == "Windows" then
		pcall(ffi.cdef, "int _isatty(int fd);")
		local ok, result = pcall(function() return ffi.C._isatty(1) ~= 0 end)
		if ok then isTTY = result end

		if isTTY then
			-- Legacy Windows consoles (conhost) ignore ANSI escapes unless VT
			-- processing is enabled. Without this, progress redraws (\x1b[2K\r)
			-- print the escape bytes literally and never clear the previous line,
			-- so each update appends a new entry instead of replacing it.
			pcall(ffi.cdef, [[
				typedef void* HANDLE;
				typedef uint32_t DWORD;
				typedef int BOOL;
				HANDLE GetStdHandle(DWORD nStdHandle);
				BOOL GetConsoleMode(HANDLE hConsoleHandle, DWORD *lpMode);
				BOOL SetConsoleMode(HANDLE hConsoleHandle, DWORD dwMode);
			]])
			pcall(function()
				local kernel32 = ffi.load("kernel32")
				local STD_OUTPUT_HANDLE = ffi.cast("DWORD", -11)
				local ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
				local hOut = kernel32.GetStdHandle(STD_OUTPUT_HANDLE)
				local mode = ffi.new("DWORD[1]")
				-- GetConsoleMode fails when stdout isn't a console (redirected), in
				-- which case there's nothing to enable.
				if kernel32.GetConsoleMode(hOut, mode) ~= 0 then
					kernel32.SetConsoleMode(hOut, mode[0] | ENABLE_VIRTUAL_TERMINAL_PROCESSING)
				end
			end)
		end

		pcall(ffi.cdef, [[
			typedef union { struct { uint32_t lo, hi; }; uint64_t val; } LARGE_INTEGER;
			int QueryPerformanceCounter(LARGE_INTEGER *lpPerformanceCount);
			int QueryPerformanceFrequency(LARGE_INTEGER *lpFrequency);
		]])
		local freqOk, freq = pcall(function()
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
		local ok, result = pcall(function() return ffi.C.isatty(1) ~= 0 end)
		if ok then isTTY = result end

		pcall(ffi.cdef, "typedef struct { long tv_sec; long tv_nsec; } timespec;")
		pcall(ffi.cdef, "int clock_gettime(int clk_id, timespec *tp);")
		local clockOk = pcall(function()
			local t = ffi.new("timespec")
			ffi.C.clock_gettime(1, t)
		end)
		if clockOk then
			now = function()
				local t = ffi.new("timespec")
				ffi.C.clock_gettime(1, t)
				local ts = t --[[@as ansi.ffi.timespec]]
				return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) * 1e-9
			end
		end
	end
	if not now then now = os.clock end
end

local ansi = {}

-- When true, ansi.progress() returns a silent handle. The test runner sets it
-- while installing dependencies so compact install bars and one-off downloads
-- (e.g. the LuaJIT tree) don't interleave flush-left with the indented test
-- results. Distinct from lde.isQuiet, which suppresses the install progress
-- line at its call site.
ansi.isQuiet = false

--- Shared no-op progress handle returned in quiet mode.
local silentProgress = {
	update = function() end,
	setLabel = function() end,
	done = function() end,
	fail = function() end,
}

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
local colors = {
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
local colorEnabled = isTTY
if colorEnabled and ffi.os ~= "Windows" then
	local term = os.getenv("TERM")
	colorEnabled = term ~= nil and term ~= "dumb"
end
if not colorEnabled and (os.getenv("GITHUB_ACTIONS") == "true" or os.getenv("GITLAB_CI") == "true") then
	colorEnabled = true
end

local noColor = os.getenv("NO_COLOR")
if noColor and noColor ~= "0" then
	colorEnabled = false
end

local forceColor = os.getenv("CLICOLOR_FORCE")
if forceColor and forceColor ~= "0" then
	colorEnabled = true
end

if not colorEnabled then
	for k in pairs(colors) do colors[k] = "" end
end

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
local ESC = "\27["

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
			local TIOCGWINSZ = (jit.os == "OSX" or jit.os == "BSD") and 0x40087468 or 0x5413
			local ws = ffi.new("uint16_t[4]") -- ws_row, ws_col, ws_xpixel, ws_ypixel
			if ffi.C.ioctl(1, TIOCGWINSZ, ws) == 0 and tonumber(ws[1]) > 0 then
				columns = math.floor(tonumber(ws[1]) or 80)
			end
		end)
	end
	if columns < 20 then columns = 80 end
end

function ansi.clearLine()
	if not isTTY then return end
	io.write(ESC .. "2K\r")
	io.flush()
end

-- progress: animated spinner with elapsed time.
-- update(ratio, info) — ratio is 0–1 or nil (indeterminate); info is optional status text.
-- setLabel(msg) — swap the label shown by the spinner and used by done/fail.
-- done(msg) / fail(msg) — finalize with checkmark or cross.

local BAR_WIDTH = 20

---@param seconds number
local function formatElapsed(seconds)
	if seconds < 0.1 then
		return string.format("%.0fms", seconds * 1000)
	elseif seconds < 10 then
		return string.format("%.2fs", seconds)
	elseif seconds < 60 then
		return string.format("%.1fs", seconds)
	else
		local m = math.floor(seconds / 60)
		local s = math.floor(seconds % 60)
		return string.format("%dm%ds", m, s)
	end
end

-- One filled bar run, colored by the bar's ratio in discrete stock-ANSI
-- steps (red → orange → yellow → green). The terminal remaps these codes to
-- the user's theme, unlike a fixed truecolor gradient — and they render on
-- any color terminal, not just truecolor ones.
---@param ratio number?
local function renderBar(ratio)
	if not ratio then return nil end
	local filled = math.floor(ratio * BAR_WIDTH)
	if filled < 0 then filled = 0 end
	if filled > BAR_WIDTH then filled = BAR_WIDTH end

	local body = string.rep("=", filled)
	local head = filled < BAR_WIDTH and ">" or ""
	local colored = body .. head
	if colored ~= "" then
		-- colors[] entries are empty strings when colors are disabled, so this
		-- is a no-op there.
		local step = ratio < 0.25 and "red"
			or ratio < 0.5 and "orange"
			or ratio < 0.75 and "yellow"
			or "green"
		colored = colors[step] .. colored .. colors.reset
	end
	local rest = string.rep(" ", BAR_WIDTH - filled - (head ~= "" and 1 or 0))
	return colors.gray .. "[" .. colors.reset .. colored .. rest .. colors.gray .. "]" .. colors.reset
end

---@class ansi.Progress
---@field update fun(self: ansi.Progress, ratio: number?, info: string?)
---@field setLabel fun(self: ansi.Progress, label: string)
---@field done fun(self: ansi.Progress, msg: string?)
---@field fail fun(self: ansi.Progress, msg: string?)

---@param label string
---@param opts { indent: boolean? }? # indent=false prints flush-left (compact install output); default indented (test runner)
---@return ansi.Progress
function ansi.progress(label, opts)
	if ansi.isQuiet then return silentProgress end
	local startTime = now()
	local indent = opts == nil or opts.indent ~= false
	local donePrefix, failPrefix, livePrefix = "  ✓ ", "  ✗ ", "  - "
	if not indent then
		donePrefix, failPrefix, livePrefix = "✓ ", "✗ ", "- "
	end

	if not isTTY then
		return {
			update = function() end,
			setLabel = function(_, newLabel)
				label = newLabel
			end,
			done = function(_, msg)
				local elapsed = formatElapsed(now() - startTime)
				io.write(colors.green ..
				donePrefix ..
				colors.reset .. (msg or label) .. " " .. colors.gray .. "(" .. elapsed .. ")" .. colors.reset .. "\n")
				io.flush()
			end,
			fail = function(_, msg)
				io.write(colors.red .. failPrefix .. colors.reset .. (msg or label) .. "\n")
				io.flush()
			end
		}
	end

	local lastRendered = nil
	local lastRatio, lastInfo
	---@type integer # physical rows the previous frame occupied (the line may wrap)
	local lastLines = 0

	--- Erase the previously rendered frame. It may have wrapped to several
	--- rows on a narrow terminal: move to its first row and clear to the end
	--- of the screen.
	local function clearLine()
		if lastLines > 1 then io.write(ESC .. (lastLines - 1) .. "A") end
		io.write("\r" .. ESC .. "J")
		lastLines = 0
		io.flush()
	end

	---@param ratio number?
	---@param info string?
	local function render(ratio, info)
		lastRatio, lastInfo = ratio, info
		local barStr = renderBar(ratio)
		local pct = ratio ? string.format("%3d%%", math.floor(ratio * 100)) : nil
		local elapsed = formatElapsed(now() - startTime)

		if pct == lastRendered then return end
		lastRendered = pct

		local line = colors.gray .. livePrefix .. colors.reset .. label
		if barStr then
			line ..= " " .. barStr .. " " .. pct
		end
		if info then
			line ..= " " .. info
		end
		line ..= " " .. colors.gray .. elapsed .. colors.reset

		clearLine()
		io.write(line)
		io.flush()
		-- Bytes == display columns for the ASCII frame; how many rows the next
		-- clear must cover if the line wrapped.
		local plain = line:gsub("\27%[[0-9;]*[A-Za-z]", "")
		lastLines = math.ceil(#plain / columns)
	end

	render(nil, nil)

	return {
		update = function(_, ratio, info)
			render(ratio, info)
		end,
		setLabel = function(_, newLabel)
			label = newLabel
			lastRendered = false -- force the next render past the pct dedupe check
			render(lastRatio, lastInfo)
		end,
		done = function(_, msg)
			local elapsed = formatElapsed(now() - startTime)
			clearLine()
			io.write(colors.green ..
			donePrefix ..
			colors.reset .. (msg or label) .. " " .. colors.gray .. "(" .. elapsed .. ")" .. colors.reset .. "\n")
			io.flush()
		end,
		fail = function(_, msg)
			clearLine()
			io.write(colors.red .. failPrefix .. colors.reset .. (msg or label) .. "\n")
			io.flush()
		end
	}
end

-- ─── Install progress ────────────────────────────────────────────────────
-- Live region for the dependency install pass. Each dependency currently
-- being materialized or built gets its own row, appearing when its work
-- starts and clearing when it finishes: `marker label built/total elapsed`,
-- where built/total is how many of the packages that dependency pulls in are
-- built. The marker is picked lazily from what is already known: 🔧 for an
-- lde package (git/path), 🪨 for a luarocks package, 🛠️ once a build.lua is
-- discovered. Below the rows sits the total bar (gray brackets, a single
-- red→green fill in discrete theme steps) with the install-wide built/building count. Nothing is
-- committed to the scrollback, so an install prints exactly one line (the
-- summary) plus whatever the caller prints. Non-TTY output prints only the
-- summary.

---@type table<string, string> # row marker key -> emoji
local INSTALL_EMOJI = {
	wrench = "🔧", -- lde package (git/path): copied or symlinked
	rock = "🪨", -- luarocks package
	tools = "🛠️", -- package running a build.lua
}

---@class ansi.InstallProgress
---@field setCurrent fun(self: ansi.InstallProgress, label: string, kind?: "wrench"|"rock"|"tools") # spawn (or refresh) a dependency's row; resets its timer
---@field setDepCount fun(self: ansi.InstallProgress, label: string, built: integer, total: integer) # update a row's built/building count
---@field update fun(self: ansi.InstallProgress, ratio: number?, info: string?) # move the total progress bar
---@field finish fun(self: ansi.InstallProgress, label: string) # remove a finished dependency's row
---@field tick fun(self: ansi.InstallProgress) # redraw the region so elapsed counters animate while builds run
---@field done fun(self: ansi.InstallProgress, summary: string) # finalize: clear the region, print `✓ summary`
---@field fail fun(self: ansi.InstallProgress, msg: string) # finalize on error: clear the region, print `✗ msg`
---@field clear fun(self: ansi.InstallProgress) # clear the region without printing anything (caller prints its own summary)

---@param fallbackLabel string # label shown on the total line while nothing is building
---@return ansi.InstallProgress
function ansi.installProgress(fallbackLabel)
	local startTime = now()
	---@type string[] # active dependency labels, in build-start order
	local rows = {}
	---@type table<string, number> # label -> build start time
	local rowStart = {}
	---@type table<string, "wrench"|"rock"|"tools"> # label -> work-kind marker
	local rowKind = {}
	---@type table<string, { built: integer, total: integer }> # label -> per-dependency built/building count
	local depCount = {}
	local ratio, info = nil, nil
	local lastRatio, lastInfo = nil, nil
	local lastRowKey = ""
	local lastDraw = 0
	---@type integer # rows the previous frame occupied
	local lastLines = 0

	--- Erase the previously rendered live region: move to its first row and
	--- clear to the end of the screen. Each row is a single short line, so no
	--- horizontal clearing is needed.
	local function clearRegion()
		if not isTTY then return end
		if lastLines > 1 then io.write(ESC .. (lastLines - 1) .. "A") end
		io.write("\r" .. ESC .. "J")
		lastLines = 0
		io.flush()
	end

	--- Write the live region (TTY only). Deduped to ~10Hz so the elapsed
	--- counters can animate without spamming the terminal.
	local function render()
		if not isTTY then return end
		local nowT = now()
		local rowKey = table.concat(rows, "\0")
		if rowKey == lastRowKey and ratio == lastRatio and info == lastInfo and nowT - lastDraw < 0.1 then
			return
		end
		lastRowKey, lastRatio, lastInfo, lastDraw = rowKey, ratio, info, nowT

		local lines = {}
		for _, label in ipairs(rows) do
			-- Each row: `marker label built/total elapsed`. The built/total
			-- count is shown only when the dependency pulls in other packages
			-- (a leaf's `0/1` is noise).
			local c = depCount[label]
			local count = c and c.total > 1 and (" " .. colors.gray .. c.built .. "/" .. c.total .. colors.reset) or ""
			local marker = ansi.supportsEmoji() and INSTALL_EMOJI[rowKind[label] or "wrench"] or ""
			lines[#lines + 1] = marker
				.. (marker ~= "" and " " or "") .. label .. count
				.. " " .. colors.gray .. formatElapsed(nowT - rowStart[label]) .. colors.reset
		end

		local total = ""
		local barStr = renderBar(ratio)
		if barStr then total ..= barStr end
		if info then total ..= " " .. colors.gray .. info .. colors.reset end
		if #rows == 0 and not barStr and not info then total ..= fallbackLabel end
		lines[#lines + 1] = total

		clearRegion()
		io.write(table.concat(lines, "\n"))
		io.flush()
		lastLines = #lines
	end

	local progress = {}

	function progress:setCurrent(label, kind)
		if not rowStart[label] then rows[#rows + 1] = label end
		rowStart[label] = now()
		rowKind[label] = kind or "wrench"
		render()
	end

	function progress:setDepCount(label, built, total)
		depCount[label] = { built = built, total = total }
		render()
	end

	function progress:update(newRatio, newInfo)
		ratio, info = newRatio, newInfo
		render()
	end

	function progress:finish(label)
		for i, l in ipairs(rows) do
			if l == label then
				table.remove(rows, i)
				break
			end
		end
		rowStart[label] = nil
		rowKind[label] = nil
		depCount[label] = nil
		render()
	end

	function progress:tick()
		render()
	end

	function progress:done(summary)
		clearRegion()
		io.write(colors.green ..
			"✓ " ..
			colors.reset .. summary .. " " .. colors.gray .. "(" .. formatElapsed(now() - startTime) .. ")" .. colors.reset .. "\n")
		io.flush()
	end

	function progress:fail(msg)
		clearRegion()
		io.write(colors.red .. "✗ " .. colors.reset .. msg .. "\n")
		io.flush()
	end

	function progress:clear()
		clearRegion()
	end

	render()
	return progress
end

-- Format a byte count for human display.
---@param bytes number
---@return string
function ansi.formatBytes(bytes)
	if bytes < 1024 then return string.format("%d B", bytes) end
	if bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024) end
	if bytes < 1024 * 1024 * 1024 then return string.format("%.1f MB", bytes / (1024 * 1024)) end
	return string.format("%.2f GB", bytes / (1024 * 1024 * 1024))
end

-- Monotonic wall-clock timestamp in seconds (Windows QPC / clock_gettime).
---@return number
function ansi.now()
	return now()
end

-- Formats seconds as a compact human duration ("140ms", "1.25s", "1m05s").
---@param seconds number
---@return string
function ansi.formatElapsed(seconds)
	return formatElapsed(seconds)
end

-- ─── Notice prefixes ─────────────────────────────────────────────────────
-- Consistent `label:` prefixes for user-facing output (colored label, gray
-- colon). Callers pass a format string plus args, exactly like ansi.printf.

---@param msg string
---@param ... any
function ansi.error(msg, ...)
	ansi.printf("{red}error{gray}:{reset} " .. msg, ...)
end

---@param msg string
---@param ... any
function ansi.warning(msg, ...)
	ansi.printf("{yellow}warning{gray}:{reset} " .. msg, ...)
end

---@param msg string
---@param ... any
function ansi.note(msg, ...)
	ansi.printf("{blue}note{gray}:{reset} " .. msg, ...)
end

---@param msg string
---@param ... any
function ansi.tip(msg, ...)
	ansi.printf("{green}tip{gray}:{reset} " .. msg, ...)
end

-- ─── Emoji support ───────────────────────────────────────────────────────
-- Emoji (e.g. the 🪨 rock marker in `lde search`) render only when the
-- terminal has an emoji font with glyph fallback. A program can't query glyph
-- coverage, so this is a heuristic over the environment: block the known-bad
-- cases (dumb/linux terminals, non-UTF-8 locales) and let NO_EMOJI force it
-- off. Most modern terminals fall through to true.
local emojiSupported = true
do
	local term = os.getenv("TERM") or ""
	if term == "dumb" or term == "linux" then
		emojiSupported = false
	end

	-- Non-UTF-8 locales can't even encode emoji.
	local locale = os.getenv("LC_ALL") or os.getenv("LC_CTYPE") or os.getenv("LANG") or ""
	local l = locale:lower()
	if locale == "" or locale == "C" or locale == "POSIX"
		or (not l:find("utf-8", 1, true) and not l:find("utf8", 1, true)) then
		emojiSupported = false
	end

	local noEmoji = os.getenv("NO_EMOJI")
	if noEmoji and noEmoji ~= "0" then
		emojiSupported = false
	end
end

--- Whether the terminal can be expected to render emoji glyphs.
---@return boolean
function ansi.supportsEmoji()
	return emojiSupported
end

return ansi
