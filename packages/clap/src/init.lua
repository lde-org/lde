local clap = {}

---@class clap.Args
---@field private raw string[]
local Args = {}
Args.__index = Args

---@return string?
function Args:pop()
	return table.remove(self.raw, 1)
end

---@return string?
function Args:peek()
	return self.raw[1]
end

---@param desiredKey string
---@return string? val
---@return number? beforePos # New position before the option key
function Args:option(desiredKey)
	for i, raw in ipairs(self.raw) do
		if string.sub(raw, 1, 2) == "--" then
			local eq = string.find(raw, "=", 1, true)
			if eq then
				local key = string.sub(raw, 3, eq - 1)
				local value = string.sub(raw, eq + 1)

				if key == desiredKey then
					table.remove(self.raw, i) -- Remove the option key
					return value, i - 1
				end
			else
				local key = string.sub(raw, 3)

				if key == desiredKey and self.raw[i + 1] ~= nil then
					local _key = table.remove(self.raw, i)
					return table.remove(self.raw, i), i - 2
				elseif key == "" then
					-- All arguments after are positional
					break
				end
			end
		end
	end
end

---@param start number?
function Args:drain(start)
	if start then
		local args = {}
		for i = start, #self.raw do
			args[#args + 1] = self.raw[i]
		end

		for i = #self.raw, start, -1 do
			table.remove(self.raw, i)
		end

		return args
	else
		local args = self.raw
		self.raw = {}
		return args
	end
end

---@return number
function Args:count()
	return #self.raw
end

---@param desiredKey string
---@return boolean
---@return number? pos
function Args:flag(desiredKey)
	for i, arg in ipairs(self.raw) do
		if string.sub(arg, 1, 2) == "--" then
			local eq = string.find(arg, "=", 1, true)
			if eq == nil then
				local key = string.sub(arg, 3)

				if key == desiredKey then
					table.remove(self.raw, i)
					return true, i - 1
				elseif key == "" then
					-- All arguments after are positional
					break
				end
			end
		end
	end

	return false, nil
end

---@param desiredKey string
---@return string? val
function Args:short(desiredKey)
	local flag = "-" .. desiredKey
	for i, arg in ipairs(self.raw) do
		if arg == "--" then break end
		if arg == flag and self.raw[i + 1] ~= nil then
			table.remove(self.raw, i)
			return table.remove(self.raw, i)
		elseif string.sub(arg, 1, #flag + 1) == flag .. "=" then
			table.remove(self.raw, i)
			return string.sub(arg, #flag + 2)
		end
	end
end

---@param rawArgs string[]
---@return clap.Args
function clap.parse(rawArgs)
	return setmetatable({ raw = rawArgs }, Args)
end

return clap
