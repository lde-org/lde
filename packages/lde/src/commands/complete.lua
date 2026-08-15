-- Hidden completion backend (`lde __complete <words...>`), invoked by the
-- scripts emitted from `lde completion`. The words are the tokens typed so
-- far, with the (possibly partial) current word last; one candidate per line
-- is printed to stdout. No output means "no suggestions" — the shell scripts
-- fall back to file completion.

local usage = require("lde.commands.usage")
local fs = require("fs")

---@param flag string
---@return boolean
local function isValueFlag(flag)
	for _, f in ipairs(usage.valueFlags) do
		if f == flag then return true end
	end
	return false
end

---@param words string[]
---@param cur string
local function emit(words, cur)
	for _, w in ipairs(words) do
		if cur == "" or w:sub(1, #cur) == cur then
			print(w)
		end
	end
end

--- List files and directories matching a partial path, for positions where a
--- Lua file can be passed (`lde <file>`, `lde run <file>`). Directories get a
--- trailing slash so the shell can drill into them. Returns nothing when the
--- directory cannot be read.
---@param cur string
---@return string[]
local function fileCandidates(cur)
	local dir, prefix = cur:match("^(.*[/\\])(.*)$")
	if not dir then
		dir, prefix = ".", cur
	end
	local entries = fs.readdir(dir)
	if not entries then return {} end
	local out = {}
	for entry in entries do
		local name = entry.name
		if prefix == "" or name:sub(1, #prefix) == prefix then
			local candidate = dir == "." and name or (dir .. name)
			out[#out + 1] = entry.type == "dir" and (candidate .. "/") or candidate
		end
	end
	table.sort(out)
	return out
end

local allFlags ---@type string[]?
local function allFlagNames()
	if not allFlags then
		allFlags = {}
		for flag in pairs(usage.globalFlags) do allFlags[#allFlags + 1] = flag end
		for flag in pairs(usage.topLevelFlags) do allFlags[#allFlags + 1] = flag end
		table.sort(allFlags)
	end
	return allFlags
end

---@param args clap.Args
local function complete(args)
	local words = args:drain()
	local n = #words
	local cur = n > 0 and words[n] or ""

	-- `--` (as its own word) starts the positional args: nothing to complete.
	for i = 1, n - 1 do
		if words[i] == "--" then return end
	end

	-- A bare `--` is the separator; `--flag=value` values are left to the shell.
	if cur == "--" or (cur:sub(1, 1) == "-" and cur:find("=", 1, true)) then
		return
	end

	-- The value position of a value-taking flag: no suggestions.
	if n >= 2 and isValueFlag(words[n - 1]) then return end

	if n <= 1 then
		-- First word: command names, or global flags when typing an option.
		if cur:sub(1, 1) == "-" then
			emit(allFlagNames(), cur)
		else
			-- Offer files only when no command matches the word, so an empty
			-- line still completes commands without file noise. The first
			-- positional can be a loose Lua file (`lde ./file.lua`).
			local matched = false
			for _, w in ipairs(usage.completionNames) do
				if cur == "" or w:sub(1, #cur) == cur then
					print(w)
					matched = true
				end
			end
			if not matched then
				emit(fileCandidates(cur), cur)
			end
		end
		return
	end

	-- Find the command: the first word that isn't an option, skipping the
	-- values of value-taking options (e.g. `-C <dir> run ...`).
	local command
	local skipValue = false
	for i = 1, n - 1 do
		local w = words[i]
		if skipValue then
			skipValue = false
		elseif isValueFlag(w) then
			skipValue = true
		elseif w:sub(1, 1) ~= "-" then
			command = w
			break
		end
	end

	-- `help`/`completion` take a command name as their positional argument.
	if command == "help" or command == "completion" then
		if cur:sub(1, 1) ~= "-" then
			emit(usage.completionNames, cur)
		end
		return
	end

	local spec = command and (usage.commands[command] or usage.commands[usage.aliases[command]])
	if spec and cur:sub(1, 1) == "-" then
		local flags = {}
		for flag in pairs(spec.options or {}) do
			flags[#flags + 1] = flag
		end
		for flag in pairs(usage.globalFlags) do
			flags[#flags + 1] = flag
		end
		table.sort(flags)
		emit(flags, cur)
	end
	-- Positional arguments: `run` takes an entry point, a script name, or a
	-- Lua file path, so offer files there; other commands get none and the
	-- shells fall back to file completion.
	if command == "run" and cur:sub(1, 1) ~= "-" then
		emit(fileCandidates(cur), cur)
	end
end

return complete
