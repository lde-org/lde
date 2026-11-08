-- SHA-256 (FIPS 180-4), used to pin package archives.
--
-- Pure LuaJIT: package tarballs are small enough that reading one into memory
-- and hashing it here is cheaper than depending on a platform crypto binary.
-- Verification happens before extraction, so a changed source server cannot
-- substitute a different tree under a published version.

local bit = require("bit")

local sha256 = {}

local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local rshift, lshift = bit.rshift, bit.lshift
local tobit = bit.tobit

local K = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
	0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
	0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
	0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
	0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
	0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
	0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
	0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
	0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local H0 = {
	0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
	0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

--- Rotate right in 32-bit space.
---@param x integer
---@param n integer
---@return integer
local function rrotate(x, n)
	return bor(rshift(x, n), lshift(x, 32 - n))
end

--- 32-bit big-endian word from four bytes.
---@param s string
---@param i integer
---@return integer
local function word(s, i)
	local a, b, c, d = s:byte(i, i + 3)
	a, b, c, d = a or 0, b or 0, c or 0, d or 0
	---@cast a integer
	---@cast b integer
	---@cast c integer
	---@cast d integer
	return tobit(bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d))
end

---@param msg string
---@return string
function sha256.sumhexa(msg)
	local length = #msg
	local fullLength = length - (length % 64)
	local bitLength = length * 8
	local high = math.floor(bitLength / 4294967296)
	local low = bitLength % 4294967296

	local h0, h1, h2, h3 = H0[1], H0[2], H0[3], H0[4]
	local h4, h5, h6, h7 = H0[5], H0[6], H0[7], H0[8]
	local w = {}

	--- Compress one 64-byte block at `offset` into the running state.
	---@param data string
	---@param offset integer
	local function compress(data, offset)
		for i = 1, 16 do
			w[i] = word(data, offset + (i - 1) * 4)
		end
		for i = 17, 64 do
			local x = w[i - 15]
			local y = w[i - 2]
			local s0 = bxor(rrotate(x, 7), rrotate(x, 18), rshift(x, 3))
			local s1 = bxor(rrotate(y, 17), rrotate(y, 19), rshift(y, 10))
			w[i] = tobit(w[i - 16] + s0 + w[i - 7] + s1)
		end

		local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
		for i = 1, 64 do
			local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
			local ch = bxor(band(e, f), band(bnot(e), g))
			local temp1 = tobit(h + S1 + ch + K[i] + w[i])
			local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
			local maj = bxor(band(a, b), band(a, c), band(b, c))
			local temp2 = tobit(S0 + maj)

			h = g
			g = f
			f = e
			e = tobit(d + temp1)
			d = c
			c = b
			b = a
			a = tobit(temp1 + temp2)
		end

		h0 = tobit(h0 + a)
		h1 = tobit(h1 + b)
		h2 = tobit(h2 + c)
		h3 = tobit(h3 + d)
		h4 = tobit(h4 + e)
		h5 = tobit(h5 + f)
		h6 = tobit(h6 + g)
		h7 = tobit(h7 + h)
	end

	for offset = 1, fullLength, 64 do
		compress(msg, offset)
	end

	-- Append padding to a small tail instead of copying the whole message.
	local remainder = length - fullLength
	local zeroCount = remainder < 56 and (55 - remainder) or (119 - remainder)
	local tail = msg:sub(fullLength + 1)
		.. "\128"
		.. string.rep("\0", zeroCount)
		.. string.char(
			math.floor(high / 16777216) % 256,
			math.floor(high / 65536) % 256,
			math.floor(high / 256) % 256,
			high % 256,
			math.floor(low / 16777216) % 256,
			math.floor(low / 65536) % 256,
			math.floor(low / 256) % 256,
			low % 256
		)
	for offset = 1, #tail, 64 do
		compress(tail, offset)
	end

	local out = {}
	for i, value in ipairs({ h0, h1, h2, h3, h4, h5, h6, h7 }) do
		out[i] = string.format("%08x", value % 4294967296)
	end
	return table.concat(out)
end

return sha256
