-- fuzzer/src/rng.lua
--
-- Seeded deterministic PRNG (xorshift32) so every fuzz run is reproducible:
-- pass the same --seed to regenerate the exact same cases.

local bit = require("bit")

---@class fuzz.Rng
---@field next fun(self: fuzz.Rng): integer # signed 32-bit
---@field int fun(self: fuzz.Rng, n: integer?): integer # 0..n-1 (or 0..2^31-2)
---@field chance fun(self: fuzz.Rng, p: number): boolean
---@field pick fun(self: fuzz.Rng, t: any[]): any
---@field bytes fun(self: fuzz.Rng, n: integer): string # printable ASCII
---@field token fun(self: fuzz.Rng, maxLen: integer?): string # word/punct/unicode mix

---@param seed integer
---@return fuzz.Rng
local function new(seed)
	local state = seed == 0 and 0x9E3779B9 or seed

	local rng = {} ---@type fuzz.Rng

	function rng.next()
		state = bit.bxor(state, bit.lshift(state, 13))
		state = bit.bxor(state, bit.rshift(state, 17))
		state = bit.bxor(state, bit.lshift(state, 5))
		return state
	end

	--- Lua's % always returns non-negative for a positive divisor, so even a
	--- negative xorshift result lands in range.
	function rng.int(n)
		local v = rng.next() % 2147483647
		if n then return v % n end
		return v
	end

	function rng.chance(p)
		return rng.int(10000) < p * 10000
	end

	function rng.pick(t)
		return t[rng.int(#t) + 1]
	end

	---@param n integer
	function rng.bytes(n)
		local chars = {}
		for i = 1, n do
			chars[i] = string.char(rng.int(95) + 32) -- 32..126
		end
		return table.concat(chars)
	end

	---@param maxLen integer?
	function rng.token(maxLen)
		maxLen = maxLen or 12
		local len = rng.int(maxLen) + 1
		local specials = { " ", "-", "_", ".", "/", "\\", "@", ":", "%", "\"", "'", "{", "}", "\27", "é", "日", "\n" }
		local chars = {}
		for i = 1, len do
			if rng.chance(0.7) then
				chars[i] = string.char(rng.int(26) + (rng.chance(0.5) and 97 or 65))
			else
				chars[i] = rng.pick(specials)
			end
		end
		return table.concat(chars)
	end

	return rng
end

return { new = new }
