local http = require("http")

local MANIFEST_URL = "https://luarocks.org/manifest"
local ROCKSPEC_BASE = "https://luarocks.org"

local luarocks = {}

---@class luarocks.ManifestEntry
---@field arch string

---@class luarocks.Manifest
---@field repository table<string, table<string, luarocks.ManifestEntry[]>>
---@field modules table
---@field commands table

---@type luarocks.Manifest?
local cachedManifest

---@alias luarocks.Token { type: "string", value: string } | { type: "ident", value: string } | { type: "sym", value: string }

---@param content string
---@return luarocks.Token[]
local function tokenize(content)
	local tokens = {}
	local i = 1
	local len = #content
	while i <= len do
		local c = content:sub(i, i)
		if c == '"' then
			local j = i + 1
			while j <= len do
				local ch = content:sub(j, j)
				if ch == '\\' then
					j = j + 2
				elseif ch == '"' then
					break
				else
					j = j + 1
				end
			end
			tokens[#tokens + 1] = { type = "string", value = content:sub(i + 1, j - 1) }
			i = j + 1
		elseif c:match("[%a_]") then
			local j = i
			while j <= len and content:sub(j, j):match("[%w_]") do j = j + 1 end
			tokens[#tokens + 1] = { type = "ident", value = content:sub(i, j - 1) }
			i = j
		elseif c:match("[{}%[%]=,]") then
			tokens[#tokens + 1] = { type = "sym", value = c }
			i = i + 1
		else
			i = i + 1
		end
	end
	return tokens
end

---@param tokens luarocks.Token[]
---@return luarocks.Manifest?, string?
local function parseManifest(tokens)
	local pos = 1

	local function peek() return tokens[pos] end

	local function consume(typ, val)
		local t = tokens[pos]
		if not t then error("unexpected end of tokens") end
		if typ and t.type ~= typ then error("expected type " .. typ .. " got " .. t.type .. " (" .. t.value .. ")") end
		if val and t.value ~= val then error("expected " .. val .. " got " .. t.value) end
		pos = pos + 1
		return t.value
	end

	local function consumeKey()
		if peek() and peek().value == "[" then
			consume("sym", "[")
			local k = consume("string")
			consume("sym", "]")
			return k
		else
			return consume("ident")
		end
	end
	while peek() and not (peek().type == "ident" and peek().value == "repository") do pos = pos + 1 end
	if not peek() then return nil, "No repository block found" end

	consume("ident", "repository")
	consume("sym", "=")
	consume("sym", "{")

	local repo = {}
	while peek() and peek().value ~= "}" do
		local pkgName = consumeKey()
		consume("sym", "=")
		consume("sym", "{")

		local versions = {}
		while peek() and peek().value ~= "}" do
			local ver = consumeKey()
			consume("sym", "=")
			consume("sym", "{")

			local entries = {}
			while peek() and peek().value ~= "}" do
				consume("sym", "{")
				consume("ident", "arch")
				consume("sym", "=")
				local arch = consume("string")
				entries[#entries + 1] = { arch = arch }
				consume("sym", "}")
				if peek() and peek().value == "," then consume("sym", ",") end
			end
			consume("sym", "}")
			if peek() and peek().value == "," then consume("sym", ",") end

			versions[ver] = entries
		end
		consume("sym", "}")
		if peek() and peek().value == "," then consume("sym", ",") end

		repo[pkgName] = versions
	end

	return { repository = repo, modules = {}, commands = {} }
end

---@return luarocks.Manifest?, string?
local function getManifest()
	if cachedManifest then return cachedManifest end

	local content, err = http.get(MANIFEST_URL)
	if not content then
		return nil, "Failed to fetch manifest: " .. (err or "")
	end

	local manifest, perr = parseManifest(tokenize(content))
	if not manifest then return nil, perr end

	cachedManifest = manifest
	return cachedManifest
end

---@param name string
---@return table<string, string>? # version -> url
---@return string? err
function luarocks.getRockspecUrls(name)
	local manifest, err = getManifest()
	if not manifest then
		return nil, err
	end

	local versions = manifest.repository[name]
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

	return urls
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

---@param name string
---@param constraint string? # e.g. ">= 1.0" or exact "1.0.0-1"; if nil, picks latest
---@return string? rockspecUrl
---@return string? err
function luarocks.getRockspecUrl(name, constraint)
	local urls, err = luarocks.getRockspecUrls(name)
	if not urls then return nil, err end

	local sorted = {}
	for v in pairs(urls) do sorted[#sorted + 1] = v end
	table.sort(sorted, function(a, b) return cmpVer(parseVer(a), parseVer(b)) > 0 end)

	if not constraint or constraint == "" then
		local url = urls[sorted[1]]
		return url or nil, url and nil or "No rockspec entry found for: " .. name
	end

	-- Parse all constraints (e.g. ">= 1.0, < 2.0")
	local constraints = {}
	for op, ver in constraint:gmatch("([><=~!]+)%s*([%d%.%-]+)") do
		constraints[#constraints + 1] = { op = op, ver = ver }
	end

	-- Exact version match if no operators found
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

		if ok then
			return urls[v]
		end
	end

	return nil, "No version of '" .. name .. "' satisfies: " .. constraint
end

---@param name string
---@param version string?
---@return string? rockspecContent
---@return string? err
function luarocks.getRockspec(name, version)
	local url, err = luarocks.getRockspecUrl(name, version)
	if not url then return nil, err end

	local content, fetchErr = http.get(url)
	if not content then
		return nil, "Failed to fetch rockspec: " .. (fetchErr or "")
	end

	return content
end

luarocks._tokenize = tokenize
luarocks._parseManifest = parseManifest

return luarocks
