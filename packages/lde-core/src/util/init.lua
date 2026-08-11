local util = {}

local fs = require("fs")
local path = require("path")
local json = require("json")
local rocked = require("rocked")
local ansi = require("ansi")
local lde = require("lde-core")
local luarocks = require("luarocks")

local curl = require("util").lazy(function() return require("curl-sys") end)
local Archive = require("util").lazy(function() return require("archive") end)

-- luarocks.org publishes per-Lua-version manifests that already exclude
-- versions incompatible with the running engine, so resolution needs no
-- per-candidate rockspec engine checks. LuaJIT is Lua 5.1.
local MANIFEST_URL = "https://luarocks.org/manifest-5.1.zip"
local MANIFEST_ENTRY = MANIFEST_URL:match("([^/]+)%.zip$") -- the file inside the zip
local MANIFEST_TTL = 60 * 60 * 24 -- 24 hours

---@type luarocks.Manifest?
local cachedManifest

---@return luarocks.Manifest?, string?
local function getManifest()
	if cachedManifest then return cachedManifest end

	-- The manifest is global registry metadata: cache it in the user-level lde
	-- directory, not the (possibly per-tree) global dir, so --tree installs share
	-- one manifest instead of re-downloading it for every tree.
	local cacheFile = path.join(lde.global.getUserDir(), "luarocks-manifest.raw")

	local stat = fs.stat(cacheFile)
	if stat and (os.time() - stat.modifyTime) < MANIFEST_TTL then
		local raw = fs.read(cacheFile)
		if raw then
			cachedManifest = luarocks.Manifest.new(raw)
			return cachedManifest
		end
	end

	local p = lde.verbose and ansi.progress("Fetching luarocks manifest") or nil

	-- luarocks.org serves the ~4.2MB raw manifest as a ~130KB zip; download the
	-- zip and decode the single "manifest-5.1" file it contains, all in memory.
	local res, err = curl().get(MANIFEST_URL)
	if not res then
		if p then p:fail() end
		return nil, "Failed to fetch manifest: " .. (err or "")
	end

	local raw, rerr = Archive().new(res.body):read(MANIFEST_ENTRY)
	if not raw then
		if p then p:fail() end
		return nil, "Failed to read manifest from zip: " .. (rerr or "")
	end

	fs.mkdirAll(lde.global.getUserDir())
	fs.write(cacheFile, raw)
	cachedManifest = luarocks.Manifest.new(raw)
	if p then p:done() end
	return cachedManifest
end

--- Cache of resolved rockspec URLs: name -> url, persisted alongside the manifest.
--- Invalidated when the manifest file is refreshed.
---@type table<string, string>?
local urlCache

local function getUrlCachePath()
	return path.join(lde.global.getUserDir(), "luarocks-url-cache-5.1.json")
end

local function loadUrlCache()
	if urlCache then return urlCache end
	local cachePath = getUrlCachePath()
	local manifestPath = path.join(lde.global.getUserDir(), "luarocks-manifest.raw")
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
		local res, fetchErr = curl().get(url)
		if not res then
			return nil, nil, "Failed to fetch rockspec: " .. (fetchErr or "")
		end

		content = res.body
		fs.write(rockspecCacheFile, content)
	end

	local ok, spec = rocked.parse(content)
	if not ok then
		return nil, nil, "Failed to parse rockspec: " .. tostring(spec)
	end ---@cast spec rocked.raw.Output

	local sourceUrl = spec.source.url
	local sourceTag = spec.source.tag or spec.source.branch

	---@type string, lde.Lockfile.Dependency
	local dir, lockEntry
	if sourceUrl:match("^git") then
		sourceUrl = util.normalizeGitUrl(sourceUrl)
		dir, commit = lde.global.getOrInitGitRepo(name, sourceUrl, branch or sourceTag, commit)
		lockEntry = { git = sourceUrl, commit = commit, rockspec = url }
	elseif sourceUrl:match("^https?://") then
		dir = lde.global.getOrInitArchive(sourceUrl)
		lockEntry = { archive = sourceUrl, rockspec = url }
	else
		return nil, nil, "Unsupported source for '" .. name .. "': " .. sourceUrl
	end

	local pkg, err = lde.Package.openRockspec(dir, url)
	return pkg, lockEntry, err
end

--- Resolves a luarocks package name/version to its source URL + arch without
--- downloading anything. Uses the persisted URL cache when possible.
---@param name string
---@param version string?
---@return string? url
---@return "src"|"rockspec"|nil arch
---@return string? err
function util.resolveLuarocksSource(name, version)
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

	return url, arch
end

--- Resolves the best version of a luarocks package plus the rockspec (metadata)
--- and .src.rock (content) URLs for that exact version. Uses the persisted URL
--- cache when possible; falls back to a manifest scan otherwise.
---
--- The manifest is the Lua-version-filtered one (manifest-5.1 for LuaJIT), so
--- every version it lists is engine-compatible by construction: the newest
--- satisfying the constraint is picked directly, with no per-candidate rockspec
--- fetches.
---@param name string
---@param constraint string?
---@return string? version
---@return string? rockspecUrl
---@return string? srcUrl
---@return string? err
function util.resolveLuarocksBest(name, constraint)
	-- URL cache fast path (unversioned lookups only)
	local cache = loadUrlCache()
	local cachedEntry = (not constraint) and cache[name] or nil
	if cachedEntry then
		local url = type(cachedEntry) == "table" and cachedEntry.url or cachedEntry
		local arch = type(cachedEntry) == "table" and cachedEntry.arch or "rockspec"
		local suffix = arch == "src" and "%.src%.rock$" or "%.rockspec$"
		local version = url:match("^.*/" .. name:gsub("([%-%.%+%*%?%[%]%^%$%(%)%%])", "%%%1") .. "%-([^/]+)" .. suffix)
		if version then
			local rockspecUrl = url:gsub("%.src%.rock$", ".rockspec")
			if arch == "src" then
				return version, rockspecUrl, url
			end
			return version, url, nil
		end
	end

	local manifest, err = getManifest()
	if not manifest then return nil, nil, nil, err end

	local candidates = luarocks.listBest(manifest, name, constraint)
	local c = candidates[1]
	if not c then
		return nil, nil, nil, "No version of '" .. name .. "'" ..
			(constraint and (" satisfies: " .. constraint) or " found")
	end

	-- Cache unversioned resolutions for future invocations
	if not constraint then
		cache[name] = { url = c.srcUrl or c.rockspecUrl, arch = c.srcUrl and "src" or "rockspec" }
		saveUrlCache()
	end

	return c.version, c.rockspecUrl, c.srcUrl, nil
end

--- Resolves a luarocks package name/version to a Package via the luarocks registry.
---@param name string
---@param version string?
---@return lde.Package?, lde.Lockfile.Dependency?, string?
function util.openLuarocksPackage(name, version)
	local url, arch, uerr = util.resolveLuarocksSource(name, version)
	if not url then return nil, nil, uerr end

	if arch == "src" then
		local archiveDir = lde.global.getOrInitArchive(url)
		-- .src.rock extracts with the rockspec at root; the source is either a
		-- subdir next to the rockspec or the nested archive (materialized by
		-- openSrcRock).
		local pkg, err = util.openSrcRock(archiveDir, url)
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

--- Cache file path for a rockspec URL.
---@param url string
---@return string
function util.rockspecCacheFile(url)
	return path.join(lde.global.getRockspecCacheDir(), (url:gsub("[^%w]", "_")))
end

--- Finds a named package inside a directory (monorepo support: lde.json can
--- live anywhere in the tree). Checks the directory itself, then scans for
--- lde.json / lpm.json config files.
---@param dir string
---@param packageName string
---@param rockspec string?
---@return lde.Package?
---@return string?
function util.findNamedPackage(dir, packageName, rockspec)
	local pkg = lde.Package.open(dir, rockspec)
	if pkg and pkg:getName() == packageName then return pkg, nil end

	for _, config in ipairs(fs.scan(dir, "**" .. path.separator .. "lde.json")) do
		pkg = lde.Package.open(path.join(dir, path.dirname(config)))
		if pkg and pkg:getName() == packageName then return pkg, nil end
	end

	-- Compatibility
	for _, config in ipairs(fs.scan(dir, "**" .. path.separator .. "lpm.json")) do
		pkg = lde.Package.open(path.join(dir, path.dirname(config)))
		if pkg and pkg:getName() == packageName then return pkg, nil end
	end

	return nil, "No lde.json with name '" .. packageName .. "' found in: " .. dir
end

--- Materializes the source tree inside an extracted .src.rock cache dir and
--- returns where the package should be opened from. A .src.rock is a zip of the
--- rockspec plus the source: either an unpacked tree (a subdir next to the
--- rockspec, e.g. tl) or the original source archive (a nested .zip/.tar.gz,
--- e.g. cerulean). When a nested archive is present it is authoritative — it is
--- extracted (once) over any stray subdirs, which may be artifacts of earlier
--- installs (e.g. a package dir left behind by an interrupted run).
---@param archiveDir string # extracted .src.rock directory
---@return string? srcDir # directory to open the package from
---@return string? rockspecPath
---@return string? err
function util.materializeSrcRock(archiveDir)
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
		return nil, nil, "No rockspec found in src rock"
	end

	if nestedArchive then
		local dir = nestedArchive:gsub("%.tar%.[gbx]z2?$", ""):gsub("%.zip$", "")
		if not fs.isdir(dir) then
			fs.mkdir(dir)
			local ok2, err2 = Archive().new(nestedArchive):extract(dir, { stripComponents = true })
			if not ok2 then
				return nil, nil, "Failed to extract nested archive in src rock: " .. (err2 or "")
			end
		end
		srcDir = dir
	end

	return srcDir or archiveDir, rockspecPath, nil
end

--- Opens the package inside an extracted .src.rock archive: finds the rockspec
--- and materializes the source tree (a source subdir, or the nested archive
--- extracted alongside the rockspec when the rock ships one).
---@param archiveDir string
---@param url string
---@return lde.Package?, string?
function util.openSrcRock(archiveDir, url)
	local srcDir, rockspecPath, err = util.materializeSrcRock(archiveDir)
	if not srcDir then
		return nil, (err or "unknown error") .. " for '" .. (url or "?") .. "'"
	end
	return lde.Package.openRockspec(srcDir, rockspecPath)
end

return util
