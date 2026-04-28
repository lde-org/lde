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
	io.write(ESC .. "2K\r")
	io.flush()
end

---@class ansi.Progress
---@field done fun(self: ansi.Progress, msg: string?)
---@field fail fun(self: ansi.Progress, msg: string?)

---@param label string
---@return ansi.Progress
function ansi.progress(label)
	io.write(colors.gray .. "  - " .. colors.reset .. label)
	io.flush()
	return {
		done = function(_, msg)
			io.write(ESC .. "2K\r" .. colors.green .. "  ✓ " .. colors.reset .. (msg or label) .. "\n")
			io.flush()
		end,
		fail = function(_, msg)
			io.write(ESC .. "2K\r" .. colors.red .. "  ✗ " .. colors.reset .. (msg or label) .. "\n")
			io.flush()
		end,
	}
end

-- ProgressBar: real-time progress bar with elapsed time.
-- update(ratio, info) — ratio is 0–1 or nil (indeterminate); info is optional status text.
-- done(msg) / fail(msg) — finalize with checkmark or cross.

local BAR_WIDTH = 20

local function formatElapsed(seconds)
	if seconds < 1 then
		return string.format("%.0fms", seconds * 1000)
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

---@class ansi.ProgressBar
---@field update fun(self: ansi.ProgressBar, ratio: number?, info: string?)
---@field done fun(self: ansi.ProgressBar, msg: string?)
---@field fail fun(self: ansi.ProgressBar, msg: string?)

---@param label string
---@return ansi.ProgressBar
function ansi.ProgressBar(label)
	local startTime = os.clock()
	local lastRendered = nil

	local function render(ratio, info)
		local barStr = renderBar(ratio)
		local pct = ratio and string.format("%3d%%", math.floor(ratio * 100)) or nil
		local elapsed = formatElapsed(os.clock() - startTime)

		local key = (barStr or "") .. (pct or "") .. (info or "")
		if key == lastRendered then return end
		lastRendered = key

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
		done = function(_, msg)
			local elapsed = formatElapsed(os.clock() - startTime)
			io.write(ESC .. "2K\r" .. colors.green .. "  ✓ " .. colors.reset .. (msg or label) .. " " .. colors.gray .. "(" .. elapsed .. ")" .. colors.reset .. "\n")
			io.flush()
		end,
		fail = function(_, msg)
			io.write(ESC .. "2K\r" .. colors.red .. "  ✗ " .. colors.reset .. (msg or label) .. "\n")
			io.flush()
		end,
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

return ansi
