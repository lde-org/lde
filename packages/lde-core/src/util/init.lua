local util = {}

local http = require("http")
local fs = require("fs")
local path = require("path")
local git = require("git")
local rocked = require("rocked")
local ansi = require("ansi")
local lde = require("lde-core")
local luarocks = require("luarocks")

local MANIFEST_URL = "https://luarocks.org/manifest"
local MANIFEST_TTL = 60 * 60 * 24 -- 24 hours

---@type luarocks.Manifest?
local cachedManifest

---@return luarocks.Manifest?, string?
local function getManifest()
	if cachedManifest then return cachedManifest end

	local cacheFile = path.join(lde.global.getDir(), "luarocks-manifest.raw")

	local stat = fs.stat(cacheFile)
	if stat and (os.time() - stat.modifyTime) < MANIFEST_TTL then
		local raw = fs.read(cacheFile)
		if raw then
			cachedManifest = luarocks.Manifest.new(raw)
			return cachedManifest
		end
	end

	local p = lde.verbose and ansi.progress("Fetching luarocks manifest") or nil
	local content, err = http.get(MANIFEST_URL)
	if not content then
		if p then p:fail() end
		return nil, "Failed to fetch manifest: " .. (err or "")
	end

	fs.write(cacheFile, content)
	cachedManifest = luarocks.Manifest.new(content)
	if p then p:done() end
	return cachedManifest
end

--- Normalises various git URL formats to a plain https:// URL.
---@param url string
---@return string
function util.normalizeGitUrl(url)
	url = url:gsub("^git%+", "")       -- git+https:// -> https://
	url = url:gsub("^git://", "https://") -- git:// -> https://
	if not url:match("%.git$") then
		url = url .. ".git"
	end
	return url
end

---@param name string # Used for error messages and git cache key
---@param url string # Rockspec URL
---@param branch string?
---@param commit string?
---@return lde.Package?, lde.Lockfile.Dependency?, string?
function util.openRockspecUrl(name, url, branch, commit)
	local content, fetchErr = http.get(url)
	if not content then
		return nil, nil, "Failed to fetch rockspec: " .. (fetchErr or "")
	end

	local ok, spec = rocked.parse(content)
	if not ok then
		return nil, nil, "Failed to parse rockspec: " .. tostring(spec)
	end ---@cast spec rocked.raw.Output

	local sourceUrl = spec.source.url
	local sourceTag = spec.source.tag

	---@type string, lde.Lockfile.Dependency
	local dir, lockEntry
	if sourceUrl:match("^git") then
		sourceUrl = util.normalizeGitUrl(sourceUrl)
		dir = lde.global.getOrInitGitRepo(name, sourceUrl, branch or sourceTag, commit)
		lockEntry = { git = sourceUrl, commit = select(2, git.getCommitHash(dir)) or commit, rockspec = url }
	elseif sourceUrl:match("^https?://") then
		dir = lde.global.getOrInitArchive(sourceUrl)
		lockEntry = { archive = sourceUrl, rockspec = url }
	else
		return nil, nil, "Unsupported source for '" .. name .. "': " .. sourceUrl
	end

	local pkg, err = lde.Package.openRockspec(dir, url)
	return pkg, lockEntry, err
end

--- Resolves a luarocks package name/version to a Package via the luarocks registry.
---@param name string
---@param version string?
---@return lde.Package?, lde.Lockfile.Dependency?, string?
function util.openLuarocksPackage(name, version)
	local manifest, err = getManifest()
	if not manifest then return nil, nil, err end
	local url, uerr = luarocks.getRockspecUrl(manifest, name, version)
	if not url then return nil, nil, uerr end
	return util.openRockspecUrl(name, url)
end

---@return luarocks.Manifest?, string?
function util.getManifest()
	return getManifest()
end

return util
