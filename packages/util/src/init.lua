local util = {}

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

---Compute a simple 32-bit FNV-1a hash of a string, returned as an 8-char hex string.
---@param s string
---@return string
function util.fnv1a(s)
	local h = 2166136261
	for i = 1, #s do
		h = bit.bxor(h, string.byte(s, i))
		h = bit.band(h * 16777619, 0xFFFFFFFF)
	end
	return string.format("%08x", bit.band(h, 0xFFFFFFFF))
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
