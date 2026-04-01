local ffi = require("ffi")

ffi.cdef [[
	void* memchr(const void* s, int c, size_t n);
]]

local ROCKSPEC_BASE = "https://luarocks.org"

local luarocks = {}

---@class luarocks.Manifest.Entry
---@field arch "rockspec" | "src" | string

---@class luarocks.Manifest
---@field _raw string
local Manifest = {}
Manifest.__index = Manifest

---@param raw string
---@return luarocks.Manifest
function Manifest.new(raw)
	return setmetatable({ _raw = raw }, Manifest)
end

---@param name string
---@return table<string, luarocks.Manifest.Entry[]>?
function Manifest:package(name)
	if not self._cache then self._cache = {} end
	if self._cache[name] ~= nil then return self._cache[name] or nil end

	local raw = self._raw
	local escaped = name:gsub("([%-%.%+%*%?%[%]%^%$%(%)%%])", "%%%1")
	-- Try quoted key: ["name"] = {
	local start = raw:find('%["' .. escaped .. '"%]%s*=%s*{')
	-- Fall back to unquoted ident key with frontier pattern: name = {
	if not start then
		start = raw:find('%f[%w_]' .. escaped .. '%f[^%w_]%s*=%s*{')
	end
	if not start then
		self._cache[name] = false; return nil
	end

	local braceStart = raw:find('{', start, true)
	if not braceStart then
		self._cache[name] = false; return nil
	end

	-- Use memchr to scan for { and } to find the matching close brace
	local ptr = ffi.cast("const char*", raw)
	local rawlen = #raw
	local openByte = string.byte('{')
	local closeByte = string.byte('}')
	local depth = 0
	local i = braceStart - 1 -- 0-based
	local blockEnd = braceStart

	while i < rawlen do
		local nextOpen  = ffi.C.memchr(ptr + i, openByte, rawlen - i)
		local nextClose = ffi.C.memchr(ptr + i, closeByte, rawlen - i)
		local openPos   = nextOpen ~= nil and tonumber(ffi.cast("size_t", nextOpen) - ffi.cast("size_t", ptr)) or rawlen
		local closePos  = nextClose ~= nil and tonumber(ffi.cast("size_t", nextClose) - ffi.cast("size_t", ptr)) or
			rawlen

		if openPos >= rawlen and closePos >= rawlen then break end

		if openPos < closePos then
			depth = depth + 1
			i = openPos + 1
		else
			depth = depth - 1
			if depth == 0 then
				blockEnd = closePos + 1 -- 1-based
				break
			end
			i = closePos + 1
		end
	end

	local block = raw:sub(braceStart, blockEnd)

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

--- Returns all entries (both src and rockspec) for a package, keyed by version.
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
	local parts = {}
	for n in (v:match("^([^%-]+)") or v):gmatch("%d+") do
		parts[#parts + 1] = tonumber(n)
	end
	return parts
end

---@param a number[]
---@param b number[]
---@return number
local function cmpVer(a, b)
	for i = 1, math.max(#a, #b) do
		local d = (a[i] or 0) - (b[i] or 0)
		if d ~= 0 then return d end
	end
	return 0
end

---@param ver string
---@param op string
---@param constraint string
---@return boolean
local function satisfies(ver, op, constraint)
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
	end

	return false
end

---@param manifest luarocks.Manifest
---@param name string
---@param constraint string?
---@return string? rockspecUrl
---@return string? err
function luarocks.getRockspecUrl(manifest, name, constraint)
	local urls, err = luarocks.getRockspecUrls(manifest, name)
	if not urls then return nil, err end

	local sorted = {}
	for v in pairs(urls) do sorted[#sorted + 1] = v end
	table.sort(sorted, function(a, b) return cmpVer(parseVer(a), parseVer(b)) > 0 end)

	if not constraint or constraint == "" then
		return urls[sorted[1]]
	end

	local constraints = {}
	for op, ver in constraint:gmatch("([><=~!]+)%s*([%d%.%-]+)") do
		constraints[#constraints + 1] = { op = op, ver = ver }
	end

	if #constraints == 0 then
		local url = urls[constraint]
		return url or nil, url and nil or "Version '" .. constraint .. "' not found for: " .. name
	end

	for _, v in ipairs(sorted) do
		local ok = true
		for _, c in ipairs(constraints) do
			if not satisfies(v, c.op, c.ver) then
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
---@return string? url
---@return string? err
local function pickUrl(urlMap, name, constraint)
	local sorted = {}
	for v in pairs(urlMap) do sorted[#sorted + 1] = v end
	table.sort(sorted, function(a, b) return cmpVer(parseVer(a), parseVer(b)) > 0 end)

	if not constraint or constraint == "" then
		return urlMap[sorted[1]]
	end

	local constraints = {}
	for op, ver in constraint:gmatch("([><=~!]+)%s*([%d%.%-]+)") do
		constraints[#constraints + 1] = { op = op, ver = ver }
	end

	if #constraints == 0 then
		local url = urlMap[constraint]
		return url or nil, url and nil or "Version '" .. constraint .. "' not found for: " .. name
	end

	for _, v in ipairs(sorted) do
		local ok = true
		for _, c in ipairs(constraints) do
			if not satisfies(v, c.op, c.ver) then ok = false; break end
		end
		if ok then return urlMap[v] end
	end

	return nil, "No version of '" .. name .. "' satisfies: " .. constraint
end

---@param manifest luarocks.Manifest
---@param name string
---@param constraint string?
---@return string? srcUrl
---@return string? err
function luarocks.getSrcUrl(manifest, name, constraint)
	local urls, err = luarocks.getSrcUrls(manifest, name)
	if not urls then return nil, err end
	return pickUrl(urls, name, constraint)
end

--- Returns a URL preferring src arch over rockspec.
--- Picks the latest (constraint-satisfying) version first, then prefers src over rockspec for that version.
---@param manifest luarocks.Manifest
---@param name string
---@param constraint string?
---@return string? url
---@return "src"|"rockspec"|nil arch
---@return string? err
function luarocks.getUrl(manifest, name, constraint)
	local versions, err = manifest:package(name)
	if not versions then return nil, nil, "Package not found in luarocks registry: " .. name end

	-- Collect all versions that satisfy the constraint
	local sorted = {}
	for v in pairs(versions) do sorted[#sorted + 1] = v end
	table.sort(sorted, function(a, b) return cmpVer(parseVer(a), parseVer(b)) > 0 end)

	local constraints = {}
	if constraint and constraint ~= "" then
		for op, ver in constraint:gmatch("([><=~!]+)%s*([%d%.%-]+)") do
			constraints[#constraints + 1] = { op = op, ver = ver }
		end
		if #constraints == 0 then
			-- Exact version string
			sorted = { constraint }
		end
	end

	for _, v in ipairs(sorted) do
		if #constraints > 0 then
			local ok = true
			for _, c in ipairs(constraints) do
				if not satisfies(v, c.op, c.ver) then ok = false; break end
			end
			if not ok then goto continue end
		end

		local entries = versions[v]
		if not entries then goto continue end

		local hasSrc, hasRockspec = false, false
		for _, entry in ipairs(entries) do
			if entry.arch == "src" then hasSrc = true end
			if entry.arch == "rockspec" then hasRockspec = true end
		end

		if hasSrc then
			return string.format("%s/%s-%s.src.rock", ROCKSPEC_BASE, name, v), "src"
		elseif hasRockspec then
			return string.format("%s/%s-%s.rockspec", ROCKSPEC_BASE, name, v), "rockspec"
		end

		::continue::
	end

	return nil, nil, "No version of '" .. name .. "'" .. (constraint and (" satisfies: " .. constraint) or " found")
end

luarocks.Manifest = Manifest

return luarocks
