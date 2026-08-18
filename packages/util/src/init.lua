local util = {}

local rapidhash = require("rapidhash")

---@param str string
function util.dedent(str)
	local lines = {}
	for line in (str .. "\n"):gmatch("(.-)\n") do
		table.insert(lines, line)
	end

	local minIndent = math.huge
	for _, line in ipairs(lines) do
		if line:match("%S") then
			local indent = line:match("^%s*")
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

	local result = table.concat(lines, "\n")
	return result:match("^(.-)%s*$") or result
end

---Compute a 64-bit rapidhash of a string, returned as a 16-char lowercase hex string.
---@param s string
---@return string
function util.hash(s)
	return rapidhash.hex(s)
end

--- Returns a lazily evaluated value: `factory()` runs on the first call,
--- every call after that returns the cached value.
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
