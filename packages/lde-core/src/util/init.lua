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

	local p = lde.isVerbose and ansi.progress("Fetching luarocks manifest") or nil

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
--- Entries survive manifest refreshes (see loadUrlCache); only the unversioned
--- fast path is skipped while the cache is older than the manifest.
---@type table<string, any>?
local urlCache

---@type boolean? # whether the loaded entries are fresh enough for the
--- unversioned fast path: entries older than the manifest may pin versions
--- that are no longer the newest, so they are re-resolved when online
local isCacheFresh

local function getUrlCachePath()
	return path.join(lde.global.getUserDir(), "luarocks-url-cache-5.1.json")
end

---@param isOffline boolean? # isOffline: trust the persisted cache even if it's
--- older than the manifest (the manifest can't be refreshed without network)
local function loadUrlCache(isOffline)
	if urlCache then return urlCache end
	local cachePath = getUrlCachePath()
	local manifestPath = path.join(lde.global.getUserDir(), "luarocks-manifest.raw")
	local cstat = fs.stat(cachePath)
	local mstat = fs.stat(manifestPath)
	-- A manifest refresh means newer versions may exist, so the fast path is
	-- skipped (isCacheFresh) — but the persisted entries are always loaded,
	-- never dropped: they are still valid pointers for offline resolution, and
	-- saveUrlCache rewrites the file with whatever is in memory, so dropping
	-- them here would permanently lose every cached URL.
	isCacheFresh = isOffline or not (cstat and mstat and cstat.modifyTime < mstat.modifyTime)
	urlCache = {}
	if cstat then
		local raw = fs.read(cachePath)
		if raw then
			local ok, decoded = pcall(json.decode, raw)
			if ok and type(decoded) == "table" then
				urlCache = decoded
			end
		end
	end
	return urlCache
end

local function saveUrlCache()
	if urlCache then
		-- Encode a fresh copy of the table: the json decoder attaches per-table
		-- key-order metadata, which makes encode() silently drop any key added
		-- after decode (e.g. a newly resolved package URL).
		local fresh = {}
		for k, v in pairs(urlCache) do fresh[k] = v end
		fs.write(getUrlCachePath(), json.encode(fresh))
	end
end

--- Safe JSON decode: returns nil + message instead of raising on malformed
--- input (the json parser crashes on some inputs, e.g. \uXXXX escapes in
--- strings) and rejects non-object documents. Package contents must never
--- be able to crash lde, so every manifest/lockfile decode goes through this.
---@param content string
---@return table?, string?
function util.decodeJson(content)
	local ok, decoded = pcall(json.decode, content)
	if not ok then
		return nil, "invalid JSON: " .. tostring(decoded)
	end
	if type(decoded) ~= "table" then
		return nil, "expected a JSON object"
	end
	return decoded, nil
end

--- Extract every package name from the luarocks manifest. A single
--- depth-tracking scan: string patterns over the 4.2MB repository block cost
--- ~250ms (Lua patterns match byte-by-byte), this reads the key at each
--- package block in ~8ms.
---@param raw string
---@return string[]
local function collectManifestNames(raw)
	local names, seen = {}, {}
	local depth = 0
	local i, n = 1, #raw

	---@param b integer?
	---@return boolean
	local function isWordByte(b)
		return b ~= nil and ((b >= 48 and b <= 57) or (b >= 65 and b <= 90)
			or (b >= 97 and b <= 122) or b == 46 or b == 45 or b == 95)
	end

	while i <= n do
		local c = raw:byte(i)
		if c == 123 then -- {
			depth = depth + 1
			i = i + 1
		elseif c == 125 then -- }
			depth = depth - 1
			i = i + 1
		elseif depth == 1 and (c == 91 or (c >= 97 and c <= 122) or c == 95) then
			if c == 91 then
				-- ["name"] = { ...
				local close = raw:find('"] = {', i, true)
				if not close then break end
				local name = raw:sub(i + 2, close - 1)
				i = close + 1
				if not seen[name] and name:find("^[%w%.%-_]+$") then
					seen[name] = true
					names[#names + 1] = name
				end
			else
				-- bare name = { ...
				local s = i
				while i <= n and isWordByte(raw:byte(i)) do i = i + 1 end
				local name = raw:sub(s, i - 1)
				while i <= n and (raw:byte(i) == 32 or raw:byte(i) == 9) do i = i + 1 end
				if raw:byte(i) == 61 then -- =
					i = i + 1
					while i <= n and (raw:byte(i) == 32 or raw:byte(i) == 9) do i = i + 1 end
					if raw:byte(i) == 123 and not seen[name] then
						seen[name] = true
						names[#names + 1] = name
					end
				end
			end
		else
			i = i + 1
		end
	end
	return names
end

--- All package names in the luarocks manifest, from a derived cache rebuilt
--- when the manifest file changes. Searching filters the ~5k names with plain
--- string.find (memchr) instead of re-parsing the 4.2MB manifest every time.
---@return string[]
function util.getManifestNames()
	local userDir = lde.global.getUserDir()
	local manifestPath = path.join(userDir, "luarocks-manifest.raw")
	local cachePath = path.join(userDir, "luarocks-names-5.1.json")
	local mstat = fs.stat(manifestPath)
	local cstat = fs.stat(cachePath)
	-- Strictly newer: same-second writes (refresh + rebuild in one second) must
	-- not be mistaken for a fresh cache.
	if mstat and cstat and cstat.modifyTime > mstat.modifyTime then
		local raw = fs.read(cachePath)
		if raw then
			local ok, decoded = pcall(json.decode, raw)
			if ok and type(decoded) == "table" then return decoded end
		end
	end

	local content = fs.read(manifestPath)
	local names = content and collectManifestNames(content) or {}
	fs.mkdirAll(userDir)
	fs.write(cachePath, json.encode(names))
	return names
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
---@param isOffline boolean?
---@return lde.Package?, lde.Lockfile.Dependency?, string?
function util.openRockspecUrl(name, url, branch, commit, isOffline)
	-- Cache rockspec content by URL to avoid re-fetching on every warm run
	local rockspecCacheFile = path.join(lde.global.getRockspecCacheDir(), (url:gsub("[^%w]", "_")))
	local content
	if fs.exists(rockspecCacheFile) then
		content = fs.read(rockspecCacheFile)
	end
	if not content then
		if isOffline then
			return nil, nil, "offline: rockspec for '" .. name .. "' is not cached (run once online to cache it)"
		end
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
		dir, commit = lde.global.getOrInitGitRepo(name, sourceUrl, branch or sourceTag, commit, isOffline)
		lockEntry = { git = sourceUrl, commit = commit, rockspec = url }
	elseif sourceUrl:match("^https?://") then
		dir = lde.global.getOrInitArchive(sourceUrl, isOffline)
		lockEntry = { archive = sourceUrl, rockspec = url }
	else
		return nil, nil, "Unsupported source for '" .. name .. "': " .. sourceUrl
	end

	local pkg, err = lde.Package.openRockspec(dir, url)
	return pkg, lockEntry, err
end

--- Resolves a luarocks package name/version to its source URL + arch without
--- downloading anything. Uses the persisted URL cache when possible.
--- With `offline`, only the URL cache is consulted — a miss errors instead of
--- fetching the manifest.
---@param name string
---@param version string?
---@param isOffline boolean?
---@return string? url
---@return "src"|"rockspec"|nil arch
---@return string? err
function util.resolveLuarocksSource(name, version, isOffline)
	-- For unversioned lookups, check the URL cache first to skip manifest scan
	local cache = loadUrlCache(isOffline)
	local cacheKey = name .. (version and ("@" .. version) or "")
	local cachedEntry = (not version) and isCacheFresh and cache[cacheKey] or nil

	local url, arch
	if cachedEntry then
		url = type(cachedEntry) == "table" and cachedEntry.url or cachedEntry
		arch = type(cachedEntry) == "table" and cachedEntry.arch or "rockspec"
	elseif isOffline then
		return nil, nil, "offline: '" .. name .. "' is not cached (run once online to cache it)"
	else
		local manifest, err = getManifest()
		if not manifest then return nil, nil, err end

		local uerr
		url, arch, uerr = luarocks.getUrl(manifest, name, version)
		if not url then return nil, nil, uerr end ---@cast url string

		-- Cache the resolved URL for future invocations
		if not version then
			cache[cacheKey] = { url = url, arch = arch }
			saveUrlCache()
		end
	end

	---@cast url string?
	---@cast arch "src"|"rockspec"|nil
	return url, arch
end

--- Populates a dependencies table from rockspec dependency strings, routing
--- git URLs ("git+https://", "git://", "*.git") to git deps and everything
--- else to luarocks deps (skipping the "lua"/"luajit" pseudo-deps).
---@param deps table<string, lde.Package.Config.Dependency>
---@param depStrs string[]
function util.addRockspecDeps(deps, depStrs)
	for _, depStr in ipairs(depStrs) do
		local gitUrl = rocked.gitDependency(depStr)
		if gitUrl then
			gitUrl = util.normalizeGitUrl(gitUrl)
			deps[lde.global.repoNameFromUrl(gitUrl)] = { git = gitUrl }
		else
			local name, version = rocked.parseDependency(depStr)
			if name and name ~= "lua" and name ~= "luajit" then
				deps[name] = { luarocks = name, version = version }
			end
		end
	end
end

--- Suggests where a package that wasn't found might actually live, for
--- "not found" error hints: a name missing from the lde registry may be a
--- luarocks rock (and vice versa); otherwise point at `lde search`.
---@param name string
---@param wasRocks boolean # true when the luarocks lookup failed
---@return string hint
function util.suggestPackage(name, wasRocks)
	if wasRocks then
		local ok = pcall(lde.global.syncRegistry)
		if ok then
			local portfile = lde.global.lookupRegistryPackage(name)
			if portfile then
				return "This package exists in the lde registry: `lde add " .. name .. "`"
			end
		end
	else
		local manifest = getManifest()
		if manifest then
			local urls = luarocks.getRockspecUrls(manifest, name)
			if urls and next(urls) then
				return "This package exists on luarocks: `lde add rocks:" .. name .. "`"
			end
		end
	end

	return "Search available packages with: `lde search " .. name .. "`"
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
	-- "@latest" always re-checks the manifest for the newest version; it must
	-- not reuse the cached resolution (which pins whatever was latest at the
	-- time it was recorded).
	local isLatest = constraint == "latest"
	if isLatest then constraint = nil end

	-- URL cache fast path (unversioned lookups only)
	local cache = loadUrlCache()
	local cachedEntry = (not constraint) and not isLatest and isCacheFresh and cache[name] or nil
	if cachedEntry then
		local url = type(cachedEntry) == "table" and cachedEntry.url or cachedEntry ---@cast url string
		local arch = type(cachedEntry) == "table" and cachedEntry.arch or "rockspec"
		local suffix = arch == "src" ? "%.src%.rock$" : "%.rockspec$"
		local version = url:match("^.*/" .. name:gsub("([%-%.%+%*%?%[%]%^%$%(%)%%])", "%%%1") .. "%-([^/]+)" .. suffix)
		if version then
			local rockspecUrl = url:gsub("%.src%.rock$", ".rockspec")
			if arch == "src" then
				return version, rockspecUrl, url
			end
			return version, url, nil
		end ---@cast version string
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

--- Finds a materialized .src.rock archive dir for a package by scanning the tar
--- cache, for when the URL cache can't resolve the name (offline runs, or the
--- URL cache entry was lost when the manifest refreshed). Cache dirs are named
--- by the sanitized download URL (<name>-<version>-<revision>.src.rock), so the
--- package name must appear followed by "-" — and not as the tail of a longer
--- name (lua-cjson vs cjson) — which is what the boundary check enforces.
---@param name string
---@return string? dir
local function findCachedSrcRock(name)
	local iter = fs.readdir(lde.global.getTarCacheDir())
	if not iter then return nil end
	for entry in iter do
		if entry.type == "dir" then
			local start = entry.name:find(name .. "-", 1, true)
			if start and start > 1 and not entry.name:sub(start - 1, start - 1):match("[%w%-]") then
				return path.join(lde.global.getTarCacheDir(), entry.name)
			end
		end
	end
	return nil
end

--- Resolves a luarocks package name/version to a Package via the luarocks registry.
---@param name string
---@param version string?
---@param isOffline boolean?
---@return lde.Package?, lde.Lockfile.Dependency?, string?
function util.openLuarocksPackage(name, version, isOffline)
	local url, arch, uerr = util.resolveLuarocksSource(name, version, isOffline)
	if not url then
		-- Offline URL-cache miss: the archive may still be materialized in the
		-- tar cache even though the URL cache entry was lost.
		if isOffline then
			local dir = findCachedSrcRock(name)
			if dir then
				local pkg, err = util.openSrcRock(dir, name)
				if not pkg then
					return nil, nil, "Failed to load src rock '" .. name .. "': " .. (err or "")
				end
				---@type lde.Lockfile.ArchiveDependency
				local lockEntry = { archive = dir }
				return pkg, lockEntry
			end
		end
		return nil, nil, uerr or ("offline: '" .. name .. "' is not cached (run once online to cache it)")
	end

	if arch == "src" then
		local archiveDir = lde.global.getOrInitArchive(url, isOffline)
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

	return util.openRockspecUrl(name, url, nil, nil, isOffline)
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
