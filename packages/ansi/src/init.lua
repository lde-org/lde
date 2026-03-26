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

return ansi
