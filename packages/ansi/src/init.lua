local ffi = require("ffi")

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
					kernel32.SetConsoleMode(hOut, bit.bor(mode[0], ENABLE_VIRTUAL_TERMINAL_PROCESSING))
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
			return tonumber(f.val)
		end)
		if freqOk then
			now = function()
				local t = ffi.new("LARGE_INTEGER")
				ffi.C.QueryPerformanceCounter(t)
				return tonumber(t.val) / freq
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
				return tonumber(t.tv_sec) + tonumber(t.tv_nsec) * 1e-9
			end
		end
	end
	if not now then now = os.clock end
end

local ansi = {}

---@alias ansi.Color
--- | "reset"
--- | "red"
--- | "green"
--- | "yellow"
--- | "blue"
--- | "magenta"
--- | "cyan"
--- | "white"
--- | "gray"
--- | "bold"
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
	blue = "\27[34m",
	magenta = "\27[35m",
	cyan = "\27[36m",
	white = "\27[37m",
	gray = "\27[90m",
	bold = "\27[1m",
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

local function renderBar(ratio)
	if not ratio then return nil end
	local filled = math.floor(ratio * BAR_WIDTH)
	if filled < 0 then filled = 0 end
	if filled > BAR_WIDTH then filled = BAR_WIDTH end
	if filled == BAR_WIDTH then
		return "[" .. string.rep("=", BAR_WIDTH) .. "]"
	else
		local remaining = BAR_WIDTH - filled
		return "[" .. string.rep("=", filled) .. ">" .. string.rep(" ", remaining - 1) .. "]"
	end
end

---@class ansi.Progress
---@field update fun(self: ansi.Progress, ratio: number?, info: string?)
---@field setLabel fun(self: ansi.Progress, label: string)
---@field done fun(self: ansi.Progress, msg: string?)
---@field fail fun(self: ansi.Progress, msg: string?)

---@param label string
---@return ansi.Progress
function ansi.progress(label)
	local startTime = now()

	if not isTTY then
		return {
			update = function() end,
			setLabel = function(_, newLabel)
				label = newLabel
			end,
			done = function(_, msg)
				local elapsed = formatElapsed(now() - startTime)
				io.write(colors.green ..
				"  ✓ " ..
				colors.reset .. (msg or label) .. " " .. colors.gray .. "(" .. elapsed .. ")" .. colors.reset .. "\n")
				io.flush()
			end,
			fail = function(_, msg)
				io.write(colors.red .. "  ✗ " .. colors.reset .. (msg or label) .. "\n")
				io.flush()
			end
		}
	end

	local lastRendered = nil
	local lastRatio, lastInfo

	local function render(ratio, info)
		lastRatio, lastInfo = ratio, info
		local barStr = renderBar(ratio)
		local pct = ratio and string.format("%3d%%", math.floor(ratio * 100)) or nil
		local elapsed = formatElapsed(now() - startTime)

		if pct == lastRendered then return end
		lastRendered = pct

		local line = ESC .. "2K\r" .. colors.gray .. "  - " .. colors.reset .. label
		if barStr then
			line = line .. " " .. barStr .. " " .. pct
		end
		if info then
			line = line .. " " .. info
		end
		line = line .. " " .. colors.gray .. elapsed .. colors.reset
		io.write(line)
		io.flush()
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
			io.write(ESC ..
			"2K\r" ..
			colors.green ..
			"  ✓ " ..
			colors.reset .. (msg or label) .. " " .. colors.gray .. "(" .. elapsed .. ")" .. colors.reset .. "\n")
			io.flush()
		end,
		fail = function(_, msg)
			io.write(ESC .. "2K\r" .. colors.red .. "  ✗ " .. colors.reset .. (msg or label) .. "\n")
			io.flush()
		end
	}
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

return ansi
