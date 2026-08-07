-- Hidden completion backend (`lde __complete <words...>`), invoked by the
-- scripts emitted from `lde completion`. The words are the tokens typed so
-- far, with the (possibly partial) current word last; one candidate per line
-- is printed to stdout. No output means "no suggestions" — the shell scripts
-- fall back to file completion.

local usage = require("lde.commands.usage")

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
			emit(usage.completionNames, cur)
		end
		return
	end

	-- Find the command: the first word that isn't an option.
	local command
	for i = 1, n - 1 do
		local w = words[i]
		if w:sub(1, 1) ~= "-" then
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
	-- Positional arguments: no suggestions; shells fall back to file completion.
end

return complete
