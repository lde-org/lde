const raw = jit.os == "Windows"
	? require("readline.raw.windows")
	: require("readline.raw.posix")

---@class readline
const readline = {}

--- The lines entered so far, shared by every `read` in the process.
---@type string[]
local history = {}

---@class readline.EditOpts
---@field prompt string
---@field readByte fun(): string?
---@field write fun(s: string)
---@field history string[]
---@field highlight (fun(s: string): string)?
---@field complete (fun(s: string, pos: integer): string?)?

---@param opts readline.EditOpts
function readline.edit(opts)
	local prompt    = opts.prompt
	local readByte  = opts.readByte
	local write     = opts.write
	const hist      = opts.history
	local highlight = opts.highlight
	local complete  = opts.complete

	local line  = ""
	local pos   = 0
	local hpos  = #hist + 1
	local saved = ""
	local ghost

	-- Whole line rewritten because a highlight changes text before the cursor too.
	local function redraw()
		ghost = (complete and pos == #line) ? complete(line, pos) : nil
		const suffix = ghost ? ("\27[2m" .. ghost .. "\27[0m") : ""
		write("\r" .. prompt .. (highlight ? highlight(line) : line) .. suffix .. "\x1b[K")
		const back = #line - pos + (ghost ? #ghost : 0)
		if back > 0 then write("\x1b[" .. back .. "D") end
	end

	-- Moving the cursor by writing it there and walking back with the same escape a terminal sends.
	---@param target integer
	local function moveTo(target)
		if target == pos then return end
		if target == 0 then write("\x1b[" .. pos .. "D") else write("\x1b[" .. (#line - pos) .. "C") end
		pos = target
	end

	write(prompt)

	while true do
		const ch = readByte()

		if ch == nil or ch == "\x04" then -- Ctrl-D: EOF on an empty line, ignored otherwise
			if #line == 0 then return nil end
		elseif ch == "\x03" then -- Ctrl-C
			write("\r\n")
			return nil
		elseif ch == "\r" or ch == "\n" then
			write("\x1b[K\r\n")
			if line ~= "" then hist[#hist + 1] = line end
			return line
		elseif ch == "\x1b" then -- an arrow key: ESC [ and then what it is
			const a = readByte()
			if a == "[" then
				const b = readByte()
				if b == "A" then
					if hpos > 1 then
						if hpos == #hist + 1 then saved = line end
						hpos -= 1
						line = hist[hpos]
						pos  = #line
						redraw()
					end
				elseif b == "B" then
					if hpos <= #hist then
						hpos += 1
						line = hpos == #hist + 1 ? saved : hist[hpos]
						pos  = #line
						redraw()
					end
				elseif b == "C" then
					if pos < #line then pos = pos + 1; write("\x1b[C") end
				elseif b == "D" then
					if pos > 0 then pos = pos - 1; write("\x1b[D") end
				elseif b == "H" or b == "1" then
					if b == "1" then readByte() end -- the `~` of a terminal's Home
					moveTo(0)
				elseif b == "F" or b == "4" then
					if b == "4" then readByte() end -- and of its End
					moveTo(#line)
				elseif b == "3" then
					readByte()
					if pos < #line then
						line = line:sub(1, pos) .. line:sub(pos + 2)
						redraw()
					end
				end
			end
		elseif ch == "\x7f" or ch == "\x08" then -- backspace
			if pos > 0 then
				line = line:sub(1, pos - 1) .. line:sub(pos + 1)
				pos -= 1
				redraw()
			end
		elseif ch == "\x01" then -- Ctrl-A
			moveTo(0)
		elseif ch == "\x05" then -- Ctrl-E
			moveTo(#line)
		elseif ch == "\x17" then -- Ctrl-W: the word before the cursor, and the spaces it follows
			local i = pos
			while i > 0 and line:sub(i, i) == " " do i = i - 1 end
			while i > 0 and line:sub(i, i) ~= " " do i = i - 1 end
			line = line:sub(1, i) .. line:sub(pos + 1)
			pos  = i
			redraw()
		elseif ch == "\x0b" then -- Ctrl-K: kill to the end
			line = line:sub(1, pos)
			redraw()
		elseif ch == "\x15" then -- Ctrl-U: kill to the start
			line = line:sub(pos + 1)
			pos  = 0
			redraw()
		elseif ch == "\x09" then -- Tab: take the suggestion the ghost is showing
			if complete and pos == #line then
				const suggestion = complete(line, pos)
				if suggestion and #suggestion > 0 then
					line = line:sub(1, pos) .. suggestion .. line:sub(pos + 1)
					pos += #suggestion
					redraw()
				end
			end
		elseif ch >= " " then
			line = line:sub(1, pos) .. ch .. line:sub(pos + 1)
			pos += 1
			redraw()
		end
	end
end

---@param prompt string
---@param highlight? fun(s: string): string
---@param complete? fun(s: string, pos: integer): string?
function readline.read(prompt, highlight, complete)
	raw.enterRaw()
	const out = readline.edit({
		prompt    = prompt,
		readByte  = raw.readByte,
		write     = function(s) io.write(s); io.flush() end,
		history   = history,
		highlight = highlight,
		complete  = complete,
	})
	raw.exitRaw()
	return out
end

return readline
