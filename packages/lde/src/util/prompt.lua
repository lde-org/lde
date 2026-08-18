local ansi = require("ansi")
local ffi = require("ffi")

local lde = require("lde-core")

local raw = jit.os == "Windows"
	and require("readline.raw.windows")
	or require("readline.raw.posix")

---@class lde.prompt
local prompt = {}

---@param fd integer
---@return boolean
local function fdIsTTY(fd)
	if ffi.os == "Windows" then
		pcall(ffi.cdef, "int _isatty(int fd);")
		local ok, result = pcall(function() return ffi.C._isatty(fd) ~= 0 end)
		return ok and result or false
	else
		pcall(ffi.cdef, "int isatty(int fd);")
		local ok, result = pcall(function() return ffi.C.isatty(fd) ~= 0 end)
		return ok and result or false
	end
end

-- The select below renders with cursor-movement escapes and reads raw key
-- presses, so it only makes sense when both stdin and stdout are terminals.
-- When either is redirected (CI, pipes, tests) scaffolding falls back to
-- defaults instead of hanging or spewing escapes into a log file.
local interactive = fdIsTTY(0) and fdIsTTY(1)
prompt.interactive = interactive

-- After an ESC byte (POSIX sends arrows byte-by-byte), check whether more of
-- the escape sequence is already pending. A bare ESC with nothing following
-- within the window quits the menu instead of blocking on a read that will
-- never arrive. Falls back to "pending" when poll is unavailable.
local PollFds, canPoll
if ffi.os ~= "Windows" then
	-- process.raw.posix already declares struct pollfd + poll (it is loaded by
	-- the time scaffolding runs); the pcalls are no-ops when it has, and
	-- declare the symbols when it hasn't.
	pcall(ffi.cdef, "struct pollfd { int fd; short events; short revents; };")
	pcall(ffi.cdef, "int poll(struct pollfd* fds, unsigned long nfds, int timeout);")
	local ok, t = pcall(ffi.typeof, "struct pollfd[?]")
	if ok then
		PollFds = t
		canPoll = ffi.C.poll ~= nil
	end
end

---@return boolean
local function escSequencePending()
	if ffi.os == "Windows" then
		-- Arrows arrive as a single string on Windows, so a lone "\x1b" byte
		-- can only be a bare escape — no peek needed.
		return false
	end
	if not canPoll then return true end
	local p = PollFds(1)
	p[0].fd = 0
	p[0].events = 1 -- POLLIN
	return ffi.C.poll(p, 1, 60) > 0
end

---@class lde.prompt.Option
---@field key string
---@field desc string
---@field color ansi.Color

---Interactive arrow-key select. ↑/↓ (or j/k) move the cursor, a number jumps
---straight to that option, Enter confirms, Esc or Ctrl+C cancels.
---@param opts { prompt: string, options: lde.prompt.Option[], default: string }
---@return string? # selected key, or nil when cancelled (Esc / Ctrl+C)
function prompt.select(opts)
	local count = #opts.options

	local idx = 1
	for i, opt in ipairs(opts.options) do
		if opt.key == opts.default then
			idx = i
			break
		end
	end

	local function row(i, selected)
		local opt = opts.options[i]
		local marker = selected and ansi.colorize("green", "> ") or "  "
		local name = ansi.colorize("bold", ansi.colorize(opt.color, opt.key))
		if selected then
			name = ansi.colorize("underline", name)
		end
		return marker .. name .. "  " .. ansi.colorize("gray", opt.desc)
	end

	-- Rewrites every option row in place, leaving the cursor on the first row.
	local function redraw()
		for i = 1, count do
			io.write("\r\x1b[2K" .. row(i, i == idx))
			if i < count then io.write("\n") end
		end
		io.write("\x1b[" .. (count - 1) .. "A\r")
		io.flush()
	end

	raw.enterRaw()

	-- Hide the terminal cursor while the menu is up — without this it floats
	-- at the end of the last-rendered row.
	io.write("\x1b[?25l")
	io.flush()

	-- Draw the prompt and options; the cursor ends up on the first option row.
	io.write("\r" .. ansi.format("{cyan}?{reset} {bold}%s{reset}", opts.prompt) .. "\n")
	for i = 1, count do
		io.write("\r" .. row(i, i == idx) .. "\n")
	end
	io.write("\x1b[" .. count .. "A\r")
	io.flush()

	local cancelled = false
	-- The input loop must always unwind raw mode, even if a key handler
	-- throws (leaving the terminal raw makes all subsequent input invisible).
	local ok, err = pcall(function()
		while true do
			local ch = raw.readByte()
			if ch == nil or ch == "\x04" then
				break -- EOF: keep the current selection
			elseif ch == "\x03" then
				cancelled = true
				break
			elseif ch == "\x1b" and not escSequencePending() then
				cancelled = true
				break
			elseif ch == "\r" or ch == "\n" then
				break -- confirm
			elseif ch == "\x1b[A" then -- Windows returns the whole sequence at once
				idx = idx > 1 and idx - 1 or count; redraw()
			elseif ch == "\x1b[B" then
				idx = idx < count and idx + 1 or 1; redraw()
			elseif ch == "\x1b" then -- POSIX: escape byte, then [ then a letter
				local a = raw.readByte()
				if a == "[" then
					local b = raw.readByte()
					if b == "A" then
						idx = idx > 1 and idx - 1 or count; redraw()
					elseif b == "B" then
						idx = idx < count and idx + 1 or 1; redraw()
					end
				else
					cancelled = true
					break
				end
			elseif ch == "k" then
				idx = idx > 1 and idx - 1 or count; redraw()
			elseif ch == "j" then
				idx = idx < count and idx + 1 or 1; redraw()
			elseif ch >= "1" and ch <= "9" then
				local n = tonumber(ch)
				if n and n >= 1 and n <= count then
					idx = n
					redraw()
				end
			end
		end
	end)

	io.write("\x1b[?25h")
	io.flush()
	raw.exitRaw()

	if not ok then
		lde.error.raise(err)
	end

	-- Collapse the options into a single answer line.
	local opt = opts.options[idx]
	local line = cancelled
		and ansi.format("{yellow}Aborted.{reset}")
		or ansi.format("{cyan}?{reset} {bold}%s{reset}: ", opts.prompt) .. ansi.colorize(opt.color, opt.key)
	io.write("\r\x1b[1A\x1b[J" .. line .. "\n")
	io.flush()

	if cancelled then return nil end
	return opt.key
end

---Interactive single-line input. Enter accepts the value; empty input accepts
---the default (when one is given) or re-prompts (when required). Esc or Ctrl+C
---cancels (returns nil). Backspace edits; arrow keys are consumed and ignored.
---@param opts { prompt: string, default: string? }
---@return string? # the entered value, or nil when cancelled
function prompt.ask(opts)
	local promptStr = opts.default
		and ansi.format("{cyan}?{reset} {bold}%s{reset} (%s): ", opts.prompt, opts.default)
		or ansi.format("{cyan}?{reset} {bold}%s{reset}: ", opts.prompt)

	while true do
		local line = ""

		local function render()
			io.write("\r\x1b[2K" .. promptStr .. line)
			io.flush()
		end

		raw.enterRaw()
		io.write("\r" .. promptStr)
		io.flush()

		local cancelled = false
		-- Always unwind raw mode, even on an unexpected error (a raw terminal
		-- makes all subsequent input invisible).
		local ok, err = pcall(function()
			while true do
				local ch = raw.readByte()
				if ch == nil or ch == "\x04" then
					break -- EOF: accept the default
				elseif ch == "\x03" then
					cancelled = true
					break
				elseif ch == "\x1b" and not escSequencePending() then
					cancelled = true
					break
				elseif ch == "\r" or ch == "\n" then
					break
				elseif ch == "\x7f" or ch == "\x08" then
					if #line > 0 then
						line = line:sub(1, #line - 1)
						render()
					end
				elseif ch == "\x1b" then
					-- An escape sequence follows (arrow keys etc.): consume it.
					local a = raw.readByte()
					if a == "[" then
						raw.readByte() -- direction letter, ignored
					end
				elseif ch >= " " then
					line = line .. ch
					render()
				end
			end
		end)
		raw.exitRaw()
		if not ok then
			lde.error.raise(err)
		end

		io.write("\n")
		io.flush()

		if cancelled then
			ansi.printf("{yellow}Aborted.{reset}")
			return nil
		end

		line = line:gsub("^%s+", ""):gsub("%s+$", "")
		if line ~= "" then return line end
		if opts.default then return opts.default end

		ansi.printf("{yellow}Name cannot be empty.{reset}")
	end
end

---Resolve the package's manifest name from a `--name` flag, an interactive
---prompt, or (non-interactive) the given default. Cancelling the prompt exits.
---@param args clap.Args
---@param default string
---@return string
function prompt.resolveName(args, default)
	local nameFlag = args:option("name")
	if nameFlag then
		return nameFlag
	end

	if not interactive then
		return default
	end

	local name = prompt.ask({ prompt = "Package name", default = default })
	if not name then
		os.exit(1)
	end
	return name
end

---Pre-install the compiler for a scaffolded language so the first `lde run`
---doesn't download it. Failures are warnings, not scaffold errors.
---@param language "lua"|"teal"|"moonscript"
function prompt.ensureCompiler(language)
	if language == "teal" then
		local ok, err = pcall(require("lde-core.teal").ensureTL)
		if not ok then
			ansi.printf("{yellow}Warning: could not install the Teal compiler: %s", tostring(err))
		end
	elseif language == "moonscript" then
		local ok, err = pcall(require("lde-core.moonscript").ensureMoon)
		if not ok then
			ansi.printf("{yellow}Warning: could not install the MoonScript compiler: %s", tostring(err))
		end
	end
end

---Resolve scaffolding choices from `--type` and `--language` flags, or from
---interactive prompts when stdin and stdout are terminals. Non-interactive
---runs with no flags keep the historical defaults (blank project, Lua).
---@param args clap.Args
---@return lde.Package.InitOptions
function prompt.scaffoldOptions(args)
	local opts = {} --[[@as lde.Package.InitOptions]]

	local typeFlag = args:option("type")
	if typeFlag then
		if typeFlag ~= "blank" and typeFlag ~= "library" then
			lde.error.raise("Invalid --type '" .. typeFlag .. "' (expected 'blank' or 'library')")
		end
		opts.type = typeFlag
	end

	local languageFlag = args:option("language")
	if languageFlag then
		if languageFlag ~= "lua" and languageFlag ~= "teal" and languageFlag ~= "moonscript" then
			lde.error.raise("Invalid --language '" .. languageFlag .. "' (expected 'lua', 'teal', or 'moonscript')")
		end
		opts.language = languageFlag
	end

	if interactive then
		if not opts.type then
			local choice = prompt.select({
				prompt = "Project type",
				options = {
					{ key = "blank",   desc = "A basic hello world app", color = "green" },
					{ key = "library", desc = "A module other projects can require()", color = "yellow" },
				},
				default = "blank",
			})
			if not choice then
				os.exit(1)
			end
			opts.type = choice
		end

		if not opts.language then
			local choice = prompt.select({
				prompt = "Language",
				options = {
					{ key = "lua",       desc = "Your typical lua project", color = "blue" },
					{ key = "moonscript", desc = "A dynamically typed whitespace based language", color = "magenta" },
					{ key = "teal",      desc = "Typed lua with type checking support", color = "cyan" },
				},
				default = "lua",
			})
			if not choice then
				os.exit(1)
			end
			opts.language = choice
		end
	end

	return opts
end

return prompt
