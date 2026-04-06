local util = {}

local http = require("http")
local fs = require("fs")
local path = require("path")
local git = require("git")
local json = require("json")
local rocked = require("rocked")
local ansi = require("ansi")
local lde = require("lde-core")
local luarocks = require("luarocks")
local process = require("process2")
local Archive = require("archive")

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

--- Cache of resolved rockspec URLs: name -> url, persisted alongside the manifest.
--- Invalidated when the manifest file is refreshed.
---@type table<string, string>?
local urlCache

local function getUrlCachePath()
	return path.join(lde.global.getDir(), "luarocks-url-cache.json")
end

local function loadUrlCache()
	if urlCache then return urlCache end
	local cachePath = getUrlCachePath()
	local manifestPath = path.join(lde.global.getDir(), "luarocks-manifest.raw")
	local cstat = fs.stat(cachePath)
	local mstat = fs.stat(manifestPath)
	if cstat and mstat and cstat.modifyTime >= mstat.modifyTime then
		local raw = fs.read(cachePath)
		if raw then
			local ok, decoded = pcall(json.decode, raw)
			if ok and type(decoded) == "table" then
				urlCache = decoded
				return urlCache
			end
		end
	end
	urlCache = {}
	return urlCache
end

local function saveUrlCache()
	if urlCache then
		fs.write(getUrlCachePath(), json.encode(urlCache))
	end
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
	-- Cache rockspec content by URL to avoid re-fetching on every warm run
	local rockspecCacheFile = path.join(lde.global.getRockspecCacheDir(), (url:gsub("[^%w]", "_")))
	local content
	if fs.exists(rockspecCacheFile) then
		content = fs.read(rockspecCacheFile)
	end
	if not content then
		local fetchErr
		content, fetchErr = http.get(url)
		if not content then
			return nil, nil, "Failed to fetch rockspec: " .. (fetchErr or "")
		end
		fs.write(rockspecCacheFile, content)
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
	-- For unversioned lookups, check the URL cache first to skip manifest scan
	local cache = loadUrlCache()
	local cacheKey = name .. (version and ("@" .. version) or "")
	local cachedEntry = (not version) and cache[cacheKey] or nil

	local url, arch
	if cachedEntry then
		url = type(cachedEntry) == "table" and cachedEntry.url or cachedEntry
		arch = type(cachedEntry) == "table" and cachedEntry.arch or "rockspec"
	else
		local manifest, err = getManifest()
		if not manifest then return nil, nil, err end

		local uerr
		url, arch, uerr = luarocks.getUrl(manifest, name, version)
		if not url then return nil, nil, uerr end

		-- Cache the resolved URL for future invocations
		if not version then
			cache[cacheKey] = { url = url, arch = arch }
			saveUrlCache()
		end
	end

	if arch == "src" then
		local archiveDir = lde.global.getOrInitArchive(url)
		-- .src.rock extracts with the rockspec at root; source may be a subdir or a nested archive.
		-- Scan once to find the rockspec, a source subdir, and any nested archive.
		local rockspecPath, srcDir, nestedArchive
		local iter = fs.readdir(archiveDir)
		if iter then
			for entry in iter do
				if entry.type == "file" and entry.name:match("%.rockspec$") then
					rockspecPath = path.join(archiveDir, entry.name)
				elseif entry.type == "dir" and not srcDir then
					srcDir = path.join(archiveDir, entry.name)
				elseif entry.type == "file" and (entry.name:match("%.zip$") or entry.name:match("%.tar%.[gbx]z2?$")) then
					nestedArchive = path.join(archiveDir, entry.name)
				end
			end
		end
		if not rockspecPath then
			return nil, nil, "No rockspec found in src rock for '" .. name .. "'"
		end

		-- If no subdir was found but a nested archive was, extract it now.
		if not srcDir and nestedArchive then
			srcDir = nestedArchive:gsub("%.tar%.[gbx]z2?$", ""):gsub("%.zip$", "")
			if not fs.isdir(srcDir) then
				fs.mkdir(srcDir)
				local ok2, err2 = Archive.new(nestedArchive):extract(srcDir, { stripComponents = true })
				if not ok2 then
					return nil, nil, "Failed to extract nested archive in src rock '" .. name .. "': " .. (err2 or "")
				end
			end
		end

		local pkg, err = lde.Package.openRockspec(srcDir or archiveDir, rockspecPath)
		if not pkg then
			return nil, nil, "Failed to load src rock '" .. name .. "': " .. (err or "")
		end

		---@type lde.Lockfile.ArchiveDependency
		local lockEntry = { archive = url }
		return pkg, lockEntry
	end

	return util.openRockspecUrl(name, url)
end

---@return luarocks.Manifest?, string?
function util.getManifest()
	return getManifest()
end

return util
