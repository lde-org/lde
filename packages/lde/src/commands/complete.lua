-- Hidden `lde __complete <words...>` backend for the `lde completion` shell scripts:
-- one candidate per line, and no output means "fall back to file completion".

const usage = require("lde.commands.usage")
const fs = require("fs")
const json = require("json")

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

--- Files/dirs matching a partial path; dirs get a trailing slash to drill in.
---@param cur string
---@return string[]
local function fileCandidates(cur)
	local dir, prefix = cur:match("^(.*[/\\])(.*)$")
	if not dir then
		dir, prefix = ".", cur
	end
	const entries = fs.readdir(dir)
	if not entries then return {} end
	local out = {}
	for entry in entries do
		local name = entry.name
		if prefix == "" or name:sub(1, #prefix) == prefix then
			const candidate = dir == "." ? name : (dir .. name)
			out[#out + 1] = entry.type == "dir" ? (candidate .. "/") : candidate
		end
	end
	table.sort(out)
	return out
end

--- Manifest script names (lpm.json preferred over lde.json, mirroring configPathAtDir).
---@return string[]?
local function scriptNames()
	const content = fs.read("lpm.json") or fs.read("lde.json")
	if not content then return nil end
	const ok, config = pcall(json.decode, content)
	if not ok or type(config) ~= "table" then return nil end
	const scripts = config.scripts
	if type(scripts) ~= "table" then return nil end
	local out = {}
	for name in pairs(scripts) do
		out[#out + 1] = name
	end
	table.sort(out)
	return out
end

---@param words string[]
---@param cur string
local function emitUnique(words, cur)
	local seen = {}
	for _, w in ipairs(words) do seen[w] = true end
	local names = {}
	for w in pairs(seen) do names[#names + 1] = w end
	table.sort(names)
	emit(names, cur)
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
	const n = #words
	const cur = n > 0 and words[n] or ""

	for i = 1, n - 1 do
		if words[i] == "--" then return end
	end

	-- `--flag=value` values are left to the shell.
	if cur == "--" or (cur:sub(1, 1) == "-" and cur:find("=", 1, true)) then
		return
	end

	if n >= 2 and usage.flagValues then
		local values = usage.flagValues[words[n - 1]]
		if values then
			emit(values, cur)
			return
		end
	end

	if n >= 2 and isValueFlag(words[n - 1]) then return end

	if n <= 1 then
		if cur:sub(1, 1) == "-" then
			emit(allFlagNames(), cur)
		else
			-- Files only when nothing else matches; a loose Lua file (`lde ./file.lua`) is also valid.
			local matched = false
			local seen = {}
			for _, w in ipairs(usage.completionNames) do
				if cur == "" or w:sub(1, #cur) == cur then
					seen[w] = true
					matched = true
				end
			end
			for _, w in ipairs(scriptNames() or {}) do
				if cur == "" or w:sub(1, #cur) == cur then
					seen[w] = true
					matched = true
				end
			end
			if not matched then
				emit(fileCandidates(cur), cur)
			else
				local names = {}
				for w in pairs(seen) do names[#names + 1] = w end
				table.sort(names)
				emit(names, cur)
			end
		end
		return
	end

	local command
	local skipValue = false
	for i = 1, n - 1 do
		const w = words[i]
		if skipValue then
			skipValue = false
		elseif isValueFlag(w) then
			skipValue = true
		elseif w:sub(1, 1) ~= "-" then
			command = w
			break
		end
	end

	if command == "help" or command == "completion" then
		if cur:sub(1, 1) ~= "-" then
			emit(usage.completionNames, cur)
		end
		return
	end

	const spec = command and (usage.commands[command] or usage.commands[usage.aliases[command]])
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
	-- `run` accepts a script name or Lua file; other commands use the shells' file completion.
	if command == "run" and cur:sub(1, 1) ~= "-" then
		local words = {}
		for _, w in ipairs(scriptNames() or {}) do words[#words + 1] = w end
		for _, w in ipairs(fileCandidates(cur)) do words[#words + 1] = w end
		emitUnique(words, cur)
	end
end

return complete
