const util = {}

const rapidhash = require("rapidhash")

-- Same source the `path` module uses, so ldeHome() joins exactly like
-- path.join() without taking a dependency on it.
local separator = package.config:sub(1, 1)

---@param str string
function util.dedent(str)
	local lines = {}
	for line in (str .. "\n"):gmatch("(.-)\n") do
		table.insert(lines, line)
	end

	local minIndent = math.huge
	for _, line in ipairs(lines) do
		if line:match("%S") then
			const indent = line:match("^%s*")
			minIndent = math.min(minIndent, #indent)
		end
	end

	if minIndent == math.huge or minIndent == 0 then
		return str
	end

	for i, line in ipairs(lines) do
		if line:match("%S") then
			lines[i] = line:sub(minIndent + 1)
		end
	end

	const result = table.concat(lines, "\n")
	return result:match("^(.-)%s*$") or result
end

---@param s string
function util.hash(s)
	return rapidhash.hex(s)
end

--- The lde home directory: `LDE_HOME` when set (its value is the lde dir
--- itself), otherwise `~/.lde`. Shared by the lde-core dir layout (which also
--- places the registry tree) and sea's LuaJIT dist cache so both agree on one
--- home.
function util.ldeHome()
	const ldeHome = os.getenv("LDE_HOME")
	if ldeHome and ldeHome ~= "" then return ldeHome end
	return (os.getenv("HOME") or os.getenv("USERPROFILE") or "") .. separator .. ".lde"
end

---@generic T
---@param factory fun(): T
---@return fun(): T
function util.lazy(factory)
	local value
	return function()
		if value == nil then value = factory() end
		return value
	end
end

return util
