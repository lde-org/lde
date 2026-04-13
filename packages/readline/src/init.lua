local raw = jit.os == "Windows"
	and require("readline.raw.windows")
	or require("readline.raw.posix")

---@class readline
local readline = {}

local history = {}

---@param opts { prompt: string, readByte: fun(): string?, write: fun(s: string), history: string[], highlight: (fun(s:string):string)?, complete: (fun(s:string, pos:integer):string?)? }
---@return string?
function readline.edit(opts)
	local prompt    = opts.prompt
	local readByte  = opts.readByte
	local write     = opts.write
	local hist      = opts.history
	local highlight = opts.highlight
	local complete  = opts.complete

	local ghost = nil

	local function redraw(line, pos)
		ghost = complete and pos == #line and complete(line, pos) or nil
		local display = highlight and highlight(line) or line
		local suffix  = ghost and ("\27[2m" .. ghost .. "\27[0m") or ""
		write("\r" .. prompt .. display .. suffix .. "\x1b[K")
		local back = #line - pos + (ghost and #ghost or 0)
		if back > 0 then write("\x1b[" .. back .. "D") end
	end

	local line  = ""
	local pos   = 0
	local hpos  = #hist + 1
	local saved = ""

	write(prompt)

	while true do
		local ch = readByte()

		if ch == nil or ch == "\x04" then
			if #line == 0 then return nil end
		elseif ch == "\x03" then -- Ctrl-C
			write("\r\n")
			return nil
		elseif ch == "\r" or ch == "\n" then
			write("\r\n")
			if line ~= "" then hist[#hist + 1] = line end
			return line
		elseif ch == "\x1b" then
			local a = readByte()
			if a == "[" then
				local b = readByte()
				if b == "A" then
					if hpos > 1 then
						if hpos == #hist + 1 then saved = line end
						hpos = hpos - 1
						line = hist[hpos]; pos = #line
						redraw(line, pos)
					end
				elseif b == "B" then
					if hpos <= #hist then
						hpos = hpos + 1
						line = hpos == #hist + 1 and saved or hist[hpos]
						pos  = #line
						redraw(line, pos)
					end
				elseif b == "C" then
					if pos < #line then
						pos = pos + 1; write("\x1b[C")
					end
				elseif b == "D" then
					if pos > 0 then
						pos = pos - 1; write("\x1b[D")
					end
				elseif b == "H" or b == "1" then
					if b == "1" then readByte() end
					if pos > 0 then
						write("\x1b[" .. pos .. "D"); pos = 0
					end
				elseif b == "F" or b == "4" then
					if b == "4" then readByte() end
					if pos < #line then
						write("\x1b[" .. (#line - pos) .. "C"); pos = #line
					end
				elseif b == "3" then
					readByte()
					if pos < #line then
						line = line:sub(1, pos) .. line:sub(pos + 2)
						redraw(line, pos)
					end
				end
			end
		elseif ch == "\x7f" or ch == "\x08" then
			if pos > 0 then
				line = line:sub(1, pos - 1) .. line:sub(pos + 1)
				pos  = pos - 1
				redraw(line, pos)
			end
		elseif ch == "\x01" then
			if pos > 0 then
				write("\x1b[" .. pos .. "D"); pos = 0
			end
		elseif ch == "\x05" then
			if pos < #line then
				write("\x1b[" .. (#line - pos) .. "C"); pos = #line
			end
		elseif ch == "\x17" then -- Ctrl-W: delete word before cursor
			local i = pos
			while i > 0 and line:sub(i, i) == " " do i = i - 1 end
			while i > 0 and line:sub(i, i) ~= " " do i = i - 1 end
			line = line:sub(1, i) .. line:sub(pos + 1)
			pos  = i
			redraw(line, pos)
		elseif ch == "\x0b" then
			line = line:sub(1, pos); redraw(line, pos)
		elseif ch == "\x15" then
			line = line:sub(pos + 1); pos = 0; redraw(line, pos)
		elseif ch == "\x09" then -- Tab: accept ghost completion
			if ghost and #ghost > 0 then
				line = line:sub(1, pos) .. ghost .. line:sub(pos + 1)
				pos  = pos + #ghost
				redraw(line, pos)
			end
		elseif ch >= " " then
			line = line:sub(1, pos) .. ch .. line:sub(pos + 1)
			pos  = pos + 1
			redraw(line, pos)
		end
	end
end

---@param prompt string
---@param highlight? fun(s:string):string
---@param complete? fun(s:string, pos:integer):string?
---@return string?
function readline.read(prompt, highlight, complete)
	raw.enterRaw()
	local out = readline.edit({
		prompt    = prompt,
		readByte  = raw.readByte,
		write     = function(s)
			io.write(s); io.flush()
		end,
		history   = history,
		highlight = highlight,
		complete  = complete,
	})
	raw.exitRaw()
	return out
end

return readline
