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

local baseEnv = { pairs = pairs, ipairs = ipairs, next = next }

---@type luarocks.Manifest?
local cachedManifest

---@return luarocks.Manifest?, string?
local function getManifest()
	if cachedManifest then return cachedManifest end

	local content, err = http.get(MANIFEST_URL)
	if not content then
		return nil, "Failed to fetch manifest: " .. (err or "")
	end

	local chunk, lerr = loadstring(content, "t")
	if not chunk then return nil, lerr end

	local oh, om, oc = debug.gethook()
	debug.sethook(function() error("Manifest took too long") end, "", 1e7)
	local env = setmetatable({}, { __index = baseEnv })
	setfenv(chunk, env)
	jit.off(chunk)
	local ok, out = pcall(chunk)
	debug.sethook(oh, om, oc)

	if not ok then return nil, tostring(out) end

	cachedManifest = env --[[@as luarocks.Manifest]]
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
		return nil, "Package not found in registry: " .. name
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

return luarocks
