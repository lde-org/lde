const ffi = require("ffi")

ffi.cdef [[
	void* memchr(const void* s, int c, size_t n);
]]

local ROCKSPEC_BASE = "https://luarocks.org"

const luarocks = {}

---@class luarocks.Manifest.Entry
---@field arch "rockspec" | "src" | string

--- Plain byte search, not the Lua pattern engine (~100x slower over the manifest).

---@param b integer?
local function isWordByte(b)
	return b ~= nil and ((b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95)
end

---@param raw string
---@param i integer
local function skipWS(raw, i)
	local c = string.byte(raw, i)
	while c == 32 or c == 9 or c == 10 or c == 13 do
		i += 1
		c = string.byte(raw, i)
	end
	return i
end

---@param raw string
---@param i integer
local function keyEqBrace(raw, i)
	i = skipWS(raw, i)
	if string.byte(raw, i) ~= 61 then return nil end -- "="
	i = skipWS(raw, i + 1)
	if string.byte(raw, i) ~= 123 then return nil end -- "{"
	return i
end

---@param raw string
---@param name string
local function findIdentKey(raw, name)
	local pos = 1
	const nlen = #name
	while true do
		local start = raw:find(name, pos, true)
		if not start then return nil end
		-- standalone identifier: previous and next byte are not word chars
		if not isWordByte(string.byte(raw, start - 1)) and not isWordByte(string.byte(raw, start + nlen)) then
			local brace = keyEqBrace(raw, start + nlen)
			if brace then return brace end
		end
		pos = start + 1
	end
end

---@param raw string
---@param name string
local function findQuotedKey(raw, name)
	local lit = '["' .. name .. '"]'
	local pos = 1
	while true do
		local start = raw:find(lit, pos, true)
		if not start then return nil end
		local brace = keyEqBrace(raw, start + #lit)
		if brace then return brace end
		pos = start + 1
	end
end

---@class luarocks.Manifest
---@field _raw string
const Manifest = {}
Manifest.__index = Manifest

---@param raw string
function Manifest.new(raw)
	return setmetatable({ _raw = raw }, Manifest)
end

---@param name string
---@return table<string, luarocks.Manifest.Entry[]>? entries
---@return string? rockspecUrl
---@return string? srcUrl
---@return string? err
function Manifest:package(name)
	if not self._cache then self._cache = {} end
	if self._cache[name] ~= nil then return self._cache[name] or nil end

	local raw = self._raw
	-- The published manifest uses unquoted identifier keys; the quoted form is a fallback.
	local braceStart = findIdentKey(raw, name) or findQuotedKey(raw, name)
	if not braceStart then
		self._cache[name] = false
		return nil, "Package not found in luarocks registry: " .. name
	end

	const ptr = ffi.cast("const char*", raw)
	const rawlen = #raw
	local openByte = string.byte('{')
	local closeByte = string.byte('}')
	local depth = 0
	local i = braceStart - 1 -- 0-based
	local blockEnd = braceStart

	while i < rawlen do
		const nextOpen  = ffi.C.memchr(ptr + i, openByte, rawlen - i)
		const nextClose = ffi.C.memchr(ptr + i, closeByte, rawlen - i)
		const openPos   = nextOpen ~= nil ? tonumber(ffi.cast("size_t", nextOpen) - ffi.cast("size_t", ptr)) : rawlen
		const closePos  = nextClose ~= nil and tonumber(ffi.cast("size_t", nextClose) - ffi.cast("size_t", ptr)) or
			rawlen

		if openPos >= rawlen and closePos >= rawlen then break end

		if openPos < closePos then
			depth += 1
			i = openPos + 1
		else
			depth -= 1
			if depth == 0 then
				blockEnd = closePos + 1 -- 1-based
				break
			end
			i = closePos + 1
		end
	end

	const block = raw:sub(braceStart, blockEnd)

	local versions = {}
	for verKey, verBody in block:gmatch('%["([^"]+)"%]%s*=%s*(%b{})') do
		local entries = {}
		for arch in verBody:gmatch('arch%s*=%s*"([^"]+)"') do
			entries[#entries + 1] = { arch = arch }
		end
		versions[verKey] = entries
	end

	self._cache[name] = versions
	return versions
end

---@param manifest luarocks.Manifest
---@param name string
---@return table<string, string>? # version -> url
---@return string? err
function luarocks.getRockspecUrls(manifest, name)
	local versions = manifest:package(name)
	if not versions then
		return nil, "Package not found in luarocks registry: " .. name
	end

	local urls = {}
	for ver, entries in pairs(versions) do
		for _, entry in ipairs(entries) do
			if entry.arch == "rockspec" then
				urls[ver] = string.format("%s/%s-%s.rockspec", ROCKSPEC_BASE, name, ver)
				break
			end
		end
	end

	if not next(urls) then
		return nil, "No rockspec entries found for: " .. name
	end

	return urls
end

---@param manifest luarocks.Manifest
---@param name string
---@return table<string, string>? # version -> url
---@return string? err
function luarocks.getSrcUrls(manifest, name)
	local versions = manifest:package(name)
	if not versions then
		return nil, "Package not found in luarocks registry: " .. name
	end

	local urls = {}
	for ver, entries in pairs(versions) do
		for _, entry in ipairs(entries) do
			if entry.arch == "src" then
				urls[ver] = string.format("%s/%s-%s.src.rock", ROCKSPEC_BASE, name, ver)
				break
			end
		end
	end

	if not next(urls) then
		return nil, "No src entries found for: " .. name
	end

	return urls
end

---@param manifest luarocks.Manifest
---@param name string
---@return table<string, luarocks.Manifest.Entry[]>? # version -> entries
---@return string? err
function luarocks.getEntries(manifest, name)
	local versions = manifest:package(name)
	if not versions then
		return nil, "Package not found in luarocks registry: " .. name
	end
	return versions
end

---@param v string
---@return number[]
local function parseVer(v)
	-- Revision ("-N") sorts ("1.0.0-2" beats "1.0.0-1"); missing compares as 0, as LuaRocks does.
	const base, rev = v:match("^([^%-]+)%-(%d+)$")
	const parts = {}
	for n in (base or v):gmatch("%d+") do
		-- Only digits arrive, so `or 0` just keeps the element a number.
		parts[#parts + 1] = tonumber(n) or 0
	end
	parts[#parts + 1] = tonumber(rev) or 0
	return parts
end

---@param a number[]
---@param b number[]
---@return number
local function cmpVer(a, b)
	for i = 1, math.max(#a, #b) do
		const d = (a[i] or 0) - (b[i] or 0)
		if d ~= 0 then return d end
	end
	return 0
end

--- "1.8.0" matches "1.8.0-1"; "1.8" matches every 1.8.x.
---@param versions table<string, any> # manifest version -> entries
---@param constraint string
local function matchExactOrPrefix(versions, constraint)
	if versions[constraint] then return constraint end

	-- Drop the synthetic revision 0 so the constraint's parts prefix the candidate's.
	const cparts = parseVer(constraint)
	const prefix = {}
	for i = 1, #cparts - 1 do prefix[i] = cparts[i] end

	local best, bestParts ---@type string?, number[]?
	for v in pairs(versions) do
		local vparts = parseVer(v)
		local ok = #vparts >= #prefix
		for i = 1, #prefix do
			if vparts[i] ~= prefix[i] then ok = false break end
		end
		-- best and bestParts are set together, so bestParts is non-nil here.
		if ok and (not best or cmpVer(vparts, bestParts or {}) > 0) then
			best, bestParts = v, vparts
		end
	end
	return best
end

---@param ver string
---@param op string
---@param constraint string
---@return boolean
function luarocks.satisfies(ver, op, constraint)
	local c = cmpVer(parseVer(ver), parseVer(constraint))
	if op == ">=" then
		return c >= 0
	elseif op == ">" then
		return c > 0
	elseif op == "<=" then
		return c <= 0
	elseif op == "<" then
		return c < 0
	elseif op == "==" or op == "=" then
		return c == 0
	elseif op == "~=" then
		return c ~= 0
	elseif op == "~>" then
		-- Pessimistic: ~> 1.2 means >= 1.2 and < 1.3; ~> 1 means >= 1 and < 2
		if c < 0 then return false end
		const cv = parseVer(constraint)
		const upper = {}
		for i = 1, #cv - 1 do upper[i] = cv[i] end
		upper[math.max(#cv - 1, 1)] = (upper[math.max(#cv - 1, 1)] or cv[1]) + 1
		return cmpVer(parseVer(ver), upper) < 0
	end

	return false
end

---@param manifest luarocks.Manifest
---@param name string
---@param constraint string?
function luarocks.getRockspecUrl(manifest, name, constraint)
	local urls, err = luarocks.getRockspecUrls(manifest, name)
	if not urls then return nil, err end

	local sorted = {}
	for v in pairs(urls) do sorted[#sorted + 1] = v end
	table.sort(sorted, |a, b| -> cmpVer(parseVer(a), parseVer(b)) > 0)

	if not constraint or constraint == "" then
		return urls[sorted[1]]
	end

	---@type { op: string, ver: string }[]
	local constraints = {}
	for op, ver in constraint:gmatch("([><=~!]+)%s*([%d%.%-]+)") do
		constraints[#constraints + 1] = { op = tostring(op), ver = tostring(ver) }
	end

	if #constraints == 0 then
		local v = matchExactOrPrefix(urls, constraint --[[@as string]])
		if v then return urls[v] end
		return nil, "Version '" .. constraint .. "' not found for: " .. name
	end

	for _, v in ipairs(sorted) do
		local ok = true
		for _, c in ipairs(constraints) do
			if not luarocks.satisfies(v, c.op, c.ver) then
				ok = false
				break
			end
		end
		if ok then return urls[v] end
	end

	return nil, "No version of '" .. name .. "' satisfies: " .. constraint
end

---@param urlMap table<string, string>
---@param name string
---@param constraint string?
local function pickUrl(urlMap, name, constraint)
	local sorted = {}
	for v in pairs(urlMap) do sorted[#sorted + 1] = v end
	table.sort(sorted, |a, b| -> cmpVer(parseVer(a), parseVer(b)) > 0)

	if not constraint or constraint == "" then
		return urlMap[sorted[1]]
	end

	---@type { op: string, ver: string }[]
	local constraints = {}
	for op, ver in constraint:gmatch("([><=~!]+)%s*([%d%.%-]+)") do
		constraints[#constraints + 1] = { op = tostring(op), ver = tostring(ver) }
	end

	if #constraints == 0 then
		local v = matchExactOrPrefix(urlMap, constraint --[[@as string]])
		if v then return urlMap[v] end
		return nil, "Version '" .. constraint .. "' not found for: " .. name
	end

	for _, v in ipairs(sorted) do
		local ok = true
		for _, c in ipairs(constraints) do
			if not luarocks.satisfies(v, c.op, c.ver) then ok = false; break end
		end
		if ok then return urlMap[v] end
	end

	return nil, "No version of '" .. name .. "' satisfies: " .. constraint
end

---@param manifest luarocks.Manifest
---@param name string
---@param constraint string?
function luarocks.getSrcUrl(manifest, name, constraint)
	local urls, err = luarocks.getSrcUrls(manifest, name)
	if not urls then return nil, err end
	return pickUrl(urls, name, constraint)
end

---@param manifest luarocks.Manifest
---@param name string
---@param constraint string?
---@return string? url
---@return "src"|"rockspec"|nil arch
---@return string? err
function luarocks.getUrl(manifest, name, constraint)
	local _, rockspecUrl, srcUrl, err = luarocks.getBest(manifest, name, constraint)
	if not rockspecUrl and not srcUrl then return nil, nil, err end
	if srcUrl then return srcUrl, "src" end
	return rockspecUrl, "rockspec"
end

--- Both URLs belong to one version, so graph resolution and content download can't disagree.
---@param manifest luarocks.Manifest
---@param name string
---@param constraint string?
---@return string? version
---@return string? rockspecUrl  -- https://luarocks.org/<name>-<ver>.rockspec (nil if no rockspec entry)
---@return string? srcUrl       -- https://luarocks.org/<name>-<ver>.src.rock (nil if no src entry)
---@return string? err
function luarocks.getBest(manifest, name, constraint)
	local versions, err = manifest:package(name)
	if not versions then return nil, nil, nil, err end

	local sorted = {}
	for v in pairs(versions) do sorted[#sorted + 1] = v end
	table.sort(sorted, |a, b| -> cmpVer(parseVer(a), parseVer(b)) > 0)

	---@type { op: string, ver: string }[]
	local constraints = {}
	if constraint and constraint ~= "" then
		for op, ver in constraint:gmatch("([><=~!]+)%s*([%d%.%-]+)") do
			constraints[#constraints + 1] = { op = tostring(op), ver = tostring(ver) }
		end
		if #constraints == 0 then
			local v = matchExactOrPrefix(versions, constraint)
			if v then sorted = { v } else sorted = {} end
		end
	end

	for _, v in ipairs(sorted) do
		if #constraints > 0 then
			local ok = true
			for _, c in ipairs(constraints) do
				if not luarocks.satisfies(v, c.op, c.ver) then ok = false; break end
			end
			if not ok then goto continue end
		end

		local entries = versions[v]
		if entries then
			local hasSrc, hasRockspec = false, false
			for _, entry in ipairs(entries) do
				if entry.arch == "src" then hasSrc = true end
				if entry.arch == "rockspec" then hasRockspec = true end
			end

			local rockspecUrl = hasRockspec ? string.format("%s/%s-%s.rockspec", ROCKSPEC_BASE, name, v) : nil
			local srcUrl = hasSrc ? string.format("%s/%s-%s.src.rock", ROCKSPEC_BASE, name, v) : nil
			if rockspecUrl or srcUrl then
				return v, rockspecUrl, srcUrl, nil
			end
		end

		::continue::
	end

	return nil, nil, nil, "No version of '" .. name .. "'" .. (constraint and (" satisfies: " .. constraint) or " found")
end

--- Newest first, so callers can skip versions the engine can't use.
---@param manifest luarocks.Manifest
---@param name string
---@param constraint string?
---@return { version: string, rockspecUrl: string?, srcUrl: string? }[]
function luarocks.listBest(manifest, name, constraint)
	local versions, _ = manifest:package(name)
	if not versions then return {} end

	local sorted = {}
	for v in pairs(versions) do sorted[#sorted + 1] = v end
	table.sort(sorted, |a, b| -> cmpVer(parseVer(a), parseVer(b)) > 0)

	---@type { op: string, ver: string }[]
	local constraints = {}
	if constraint and constraint ~= "" then
		for op, ver in constraint:gmatch("([><=~!]+)%s*([%d%.%-]+)") do
			constraints[#constraints + 1] = { op = tostring(op), ver = tostring(ver) }
		end
		if #constraints == 0 then
			local v = matchExactOrPrefix(versions, constraint)
			if v then sorted = { v } else sorted = {} end
		end
	end

	const out = {}
	for _, v in ipairs(sorted) do
		if #constraints > 0 then
			local ok = true
			for _, c in ipairs(constraints) do
				if not luarocks.satisfies(v, c.op, c.ver) then ok = false; break end
			end
			if not ok then goto continue end
		end

		local entries = versions[v]
		if entries then
			local hasSrc, hasRockspec = false, false
			for _, entry in ipairs(entries) do
				if entry.arch == "src" then hasSrc = true end
				if entry.arch == "rockspec" then hasRockspec = true end
			end
			out[#out + 1] = {
				version = v,
				rockspecUrl = hasRockspec ? string.format("%s/%s-%s.rockspec", ROCKSPEC_BASE, name, v) : nil,
				srcUrl = hasSrc ? string.format("%s/%s-%s.src.rock", ROCKSPEC_BASE, name, v) : nil,
			}
		end
		::continue::
	end
	return out
end

luarocks.Manifest = Manifest

return luarocks
