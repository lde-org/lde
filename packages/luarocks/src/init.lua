local ffi = require("ffi")

ffi.cdef [[
	void* memchr(const void* s, int c, size_t n);
]]

local ROCKSPEC_BASE = "https://luarocks.org"

local luarocks = {}

---@class luarocks.Manifest.Entry
---@field arch "rockspec" | "src" | string

--- Byte helpers for locating package blocks in the manifest without invoking
--- the Lua pattern engine (which is ~100x slower than a plain search over the
--- multi-megabyte manifest).

---@param b integer?
---@return boolean
local function isWordByte(b)
	return b ~= nil and ((b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95)
end

--- Skip whitespace (space, tab, newline, CR) starting at 1-based index i.
---@param raw string
---@param i integer
---@return integer
local function skipWS(raw, i)
	local c = string.byte(raw, i)
	while c == 32 or c == 9 or c == 10 or c == 13 do
		i = i + 1
		c = string.byte(raw, i)
	end
	return i
end

--- Given a position right after a key literal, verify it is followed by
--- optional whitespace, "=", optional whitespace, "{". Returns the 1-based
--- index of "{" or nil.
---@param raw string
---@param i integer
---@return integer?
local function keyEqBrace(raw, i)
	i = skipWS(raw, i)
	if string.byte(raw, i) ~= 61 then return nil end -- "="
	i = skipWS(raw, i + 1)
	if string.byte(raw, i) ~= 123 then return nil end -- "{"
	return i
end

--- Find an unquoted identifier key: `name = {`.
---@param raw string
---@param name string
---@return integer? bracePos
local function findIdentKey(raw, name)
	local pos = 1
	local nlen = #name
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

--- Find a quoted key: `["name"] = {`.
---@param raw string
---@param name string
---@return integer? bracePos
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
	-- Find the package block with a plain (non-pattern) search. The published
	-- manifest uses unquoted identifier keys ("busted = {"); a quoted form is
	-- kept as a fallback for other serializers.
	local braceStart = findIdentKey(raw, name) or findQuotedKey(raw, name)
	if not braceStart then
		self._cache[name] = false
		return nil, "Package not found in luarocks registry: " .. name
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
	-- LuaRocks version_revision: the revision ("-N") is part of the version and
	-- must sort too, so "1.0.0-2" beats "1.0.0-1" (previously the revision was
	-- dropped, leaving equal versions to be ordered nondeterministically by
	-- table.sort). A missing revision compares as 0, matching LuaRocks (so
	-- "0.5-0" satisfies ">= 0.5", e.g. the http rock's lpeg_patterns dep).
	local base, rev = v:match("^([^%-]+)%-(%d+)$")
	local parts = {}
	for n in (base or v):gmatch("%d+") do
		parts[#parts + 1] = tonumber(n)
	end
	parts[#parts + 1] = tonumber(rev) or 0
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
		-- Pessimistic constraint: >= ver and < ver with last segment dropped + penultimate incremented
		-- e.g. ~> 1.2 means >= 1.2 and < 1.3; ~> 1 means >= 1 and < 2
		if c < 0 then return false end
		local cv = parseVer(constraint)
		local upper = {}
		for i = 1, #cv - 1 do upper[i] = cv[i] end
		upper[math.max(#cv - 1, 1)] = (upper[math.max(#cv - 1, 1)] or cv[1]) + 1
		return cmpVer(parseVer(ver), upper) < 0
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
			if not luarocks.satisfies(v, c.op, c.ver) then ok = false; break end
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
	local _, rockspecUrl, srcUrl, err = luarocks.getBest(manifest, name, constraint)
	if not rockspecUrl and not srcUrl then return nil, nil, err end
	if srcUrl then return srcUrl, "src" end
	return rockspecUrl, "rockspec"
end

--- Resolves the best (constraint-satisfying) version of a package and the
--- metadata + content artifacts to fetch for it. Both URLs belong to the same
--- version, so graph resolution (rockspec) and content download (.src.rock)
--- can never disagree on which version they target.
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

			local rockspecUrl = hasRockspec and string.format("%s/%s-%s.rockspec", ROCKSPEC_BASE, name, v) or nil
			local srcUrl = hasSrc and string.format("%s/%s-%s.src.rock", ROCKSPEC_BASE, name, v) or nil
			if rockspecUrl or srcUrl then
				return v, rockspecUrl, srcUrl, nil
			end
		end

		::continue::
	end

	return nil, nil, nil, "No version of '" .. name .. "'" .. (constraint and (" satisfies: " .. constraint) or " found")
end

--- Returns every (constraint-satisfying) version of a package, newest first,
--- with the metadata (rockspec) and content (.src.rock) artifact URLs for each.
--- Callers can walk the list to skip versions the running engine can't use
--- (e.g. cqueues-…-54 declares "lua == 5.4" and must be skipped on LuaJIT).
---@param manifest luarocks.Manifest
---@param name string
---@param constraint string?
---@return { version: string, rockspecUrl: string?, srcUrl: string? }[]
function luarocks.listBest(manifest, name, constraint)
	local versions, err = manifest:package(name)
	if not versions then return {} end

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

	local out = {}
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
				rockspecUrl = hasRockspec and string.format("%s/%s-%s.rockspec", ROCKSPEC_BASE, name, v) or nil,
				srcUrl = hasSrc and string.format("%s/%s-%s.src.rock", ROCKSPEC_BASE, name, v) or nil,
			}
		end
		::continue::
	end
	return out
end

luarocks.Manifest = Manifest

return luarocks
