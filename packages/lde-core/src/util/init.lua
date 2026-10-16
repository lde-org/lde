const util = {}

const fs = require("fs")
const path = require("path")
const json = require("json")
const rocked = require("rocked")
const ansi = require("ansi")
local lde = require("lde-core")
local luarocks = require("luarocks")

const curl = require("util").lazy(function() return require("curl-sys") end)
const Archive = require("util").lazy(function() return require("archive") end)

-- luarocks.org's per-Lua-version manifests already exclude incompatible versions, so no per-candidate engine checks are needed; LuaJIT is Lua 5.1.
const MANIFEST_URL = "https://luarocks.org/manifest-5.1.zip"
const MANIFEST_ENTRY = MANIFEST_URL:match("([^/]+)%.zip$")
const MANIFEST_TTL = 60 * 60 * 24

---@type luarocks.Manifest?
local cachedManifest

---@return luarocks.Manifest?, string?
local function getManifest()
	if cachedManifest then return cachedManifest end

	-- User-level (not per-tree) so --tree installs share one manifest instead of re-downloading.
	local cacheFile = path.join(lde.global.getUserDir(), "luarocks-manifest.raw")

	const stat = fs.stat(cacheFile)
	if stat and (os.time() - stat.modifyTime) < MANIFEST_TTL then
		local raw = fs.read(cacheFile)
		if raw then
			cachedManifest = luarocks.Manifest.new(raw)
			return cachedManifest
		end
	end

	const p = lde.isVerbose ? ansi.progress("Fetching luarocks manifest") : nil

	-- The 4.2MB raw manifest is served as a ~130KB zip; download and decode it in memory.
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

--- Resolved-rockspec-URL cache (name -> url), persisted alongside the manifest; entries survive manifest refreshes, only the unversioned fast path is skipped while stale.
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
	-- Persisted entries are always loaded though the fast path is skipped: saveUrlCache rewrites from memory, so dropping them would lose cached URLs permanently.
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
		-- Fresh copy: the json decoder's per-table key-order metadata makes encode() silently drop keys added after decode.
		const fresh = {}
		for k, v in pairs(urlCache) do fresh[k] = v end
		fs.write(getUrlCachePath(), json.encode(fresh))
	end
end

--- Returns nil+message instead of raising (the json parser crashes on some inputs, e.g. \uXXXX escapes) and rejects non-objects; package contents must never crash lde.
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

--- Single depth-tracking scan of the manifest: string patterns over the 4.2MB block cost ~250ms, this reads each package key in ~8ms.
---@param raw string
---@return string[]
local function collectManifestNames(raw)
	local names, seen = {}, {}
	local depth = 0
	local i, n = 1, #raw

	---@param b integer?
	local function isWordByte(b)
		return b ~= nil and ((b >= 48 and b <= 57) or (b >= 65 and b <= 90)
			or (b >= 97 and b <= 122) or b == 46 or b == 45 or b == 95)
	end

	while i <= n do
		local c = raw:byte(i)
		if c == 123 then
			depth = depth + 1
			i += 1
		elseif c == 125 then
			depth = depth - 1
			i += 1
		elseif depth == 1 and (c == 91 or (c >= 97 and c <= 122) or c == 95) then
			if c == 91 then
				const close = raw:find('"] = {', i, true)
				if not close then break end
				local name = raw:sub(i + 2, close - 1)
				i = close + 1
				if not seen[name] and name:find("^[%w%.%-_]+$") then
					seen[name] = true
					names[#names + 1] = name
				end
			else
				local s = i
				while i <= n and isWordByte(raw:byte(i)) do i = i + 1 end
				local name = raw:sub(s, i - 1)
				while i <= n and (raw:byte(i) == 32 or raw:byte(i) == 9) do i = i + 1 end
				if raw:byte(i) == 61 then
					i = i + 1
					while i <= n and (raw:byte(i) == 32 or raw:byte(i) == 9) do i = i + 1 end
					if raw:byte(i) == 123 and not seen[name] then
						seen[name] = true
						names[#names + 1] = name
					end
				end
			end
		else
			i += 1
		end
	end
	return names
end

--- Names come from a cache rebuilt when the manifest changes; searching then filters ~5k names with memchr instead of re-parsing 4.2MB.
function util.getManifestNames()
	local userDir = lde.global.getUserDir()
	local manifestPath = path.join(userDir, "luarocks-manifest.raw")
	local cachePath = path.join(userDir, "luarocks-names-5.1.json")
	local mstat = fs.stat(manifestPath)
	local cstat = fs.stat(cachePath)
	-- Strictly newer: same-second writes must not be mistaken for a fresh cache.
	if mstat and cstat and cstat.modifyTime > mstat.modifyTime then
		local raw = fs.read(cachePath)
		if raw then
			local ok, decoded = pcall(json.decode, raw)
			if ok and type(decoded) == "table" then return decoded end
		end
	end

	local content = fs.read(manifestPath)
	const names = content ? collectManifestNames(content) : {}
	fs.mkdirAll(userDir)
	fs.write(cachePath, json.encode(names))
	return names
end

---@param url string
function util.normalizeGitUrl(url)
	url = url:gsub("^git%+", "")
	url = url:gsub("^git://", "https://")
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
		-- The package lives in the archive's source directory (source.dir, or the
		-- single top-level directory), not at the extraction root.
		---@type string?
		local sourceDir
		dir, sourceDir = lde.global.getOrInitArchive(sourceUrl, isOffline, spec.source)
		dir = sourceDir
		lockEntry = { archive = sourceUrl, rockspec = url }
	else
		return nil, nil, "Unsupported source for '" .. name .. "': " .. sourceUrl
	end

	local pkg, err = lde.Package.openRockspec(dir, url)
	return pkg, lockEntry, err
end

--- Source URL + arch without downloading; offline consults only the URL cache and errors on a miss instead of fetching the manifest.
---@param name string
---@param version string?
---@param isOffline boolean?
---@return string? url
---@return "src"|"rockspec"|nil arch
---@return string? err
function util.resolveLuarocksSource(name, version, isOffline)
	local cache = loadUrlCache(isOffline)
	const cacheKey = name .. (version and ("@" .. version) or "")
	local cachedEntry = ((not version) and isCacheFresh) ? cache[cacheKey] : nil

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

		if not version then
			cache[cacheKey] = { url = url, arch = arch }
			saveUrlCache()
		end
	end

	---@cast url string?
	---@cast arch "src"|"rockspec"|nil
	return url, arch
end

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

--- "not found" hint: a name missing from one registry may exist in the other, else point at `lde search`.
---@param name string
---@param wasRocks boolean # true when the luarocks lookup failed
function util.suggestPackage(name, wasRocks)
	if wasRocks then
		local ok = pcall(require("lde-core.global").syncRegistry)
		if ok then
			const portfile = lde.global.lookupRegistryPackage(name)
			if portfile then
				return "This package exists in the lde registry: `lde add " .. name .. "`"
			end
		end
	else
		local manifest = getManifest()
		if manifest then
			const urls = luarocks.getRockspecUrls(manifest, name)
			if urls and next(urls) then
				return "This package exists on luarocks: `lde add rocks:" .. name .. "`"
			end
		end
	end

	return "Search available packages with: `lde search " .. name .. "`"
end

--- Best version with rockspec/src URLs; the Lua-version-filtered manifest makes every listed version engine-compatible, so the newest satisfying the constraint is picked with no per-candidate fetches.
---@param name string
---@param constraint string?
---@return string? version
---@return string? rockspecUrl
---@return string? srcUrl
---@return string? err
function util.resolveLuarocksBest(name, constraint)
	-- "@latest" must re-check the manifest: the cache pins whatever was latest when recorded.
	const isLatest = constraint == "latest"
	if isLatest then constraint = nil end

	local cache = loadUrlCache()
	local cachedEntry = ((not constraint) and not isLatest and isCacheFresh) ? cache[name] : nil
	if cachedEntry then
		local url = type(cachedEntry) == "table" and cachedEntry.url or cachedEntry ---@cast url string
		local arch = type(cachedEntry) == "table" and cachedEntry.arch or "rockspec"
		const suffix = arch == "src" ? "%.src%.rock$" : "%.rockspec$"
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

	const candidates = luarocks.listBest(manifest, name, constraint)
	local c = candidates[1]
	if not c then
		return nil, nil, nil, "No version of '" .. name .. "'" ..
			(constraint and (" satisfies: " .. constraint) or " found")
	end

	if not constraint then
		cache[name] = { url = c.srcUrl or c.rockspecUrl, arch = c.srcUrl and "src" or "rockspec" }
		saveUrlCache()
	end

	return c.version, c.rockspecUrl, c.srcUrl, nil
end

--- Scans the tar cache (dirs named <name>-<version>-<revision>.src.rock) for when the URL cache can't resolve; the boundary check keeps `cjson` from matching `lua-cjson`.
---@param name string
local function findCachedSrcRock(name)
	local iter = fs.readdir(lde.global.getTarCacheDir())
	if not iter then return nil end
	for entry in iter do
		if entry.type == "dir" then
			const start = entry.name:find(name .. "-", 1, true)
			if start and start > 1 and not entry.name:sub(start - 1, start - 1):match("[%w%-]") then
				return path.join(lde.global.getTarCacheDir(), entry.name)
			end
		end
	end
	return nil
end

---@param name string
---@param version string?
---@param isOffline boolean?
---@return lde.Package?, lde.Lockfile.Dependency?, string?
function util.openLuarocksPackage(name, version, isOffline)
	local url, arch, uerr = util.resolveLuarocksSource(name, version, isOffline)
	if not url then
		-- Offline URL-cache miss: the archive may still be in the tar cache.
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
		local archiveDir = lde.global.getOrInitArchive(url --[[@as string]], isOffline)
		-- .src.rock extracts with the rockspec at root; source is a subdir or the nested archive.
		local pkg, err = util.openSrcRock(archiveDir --[[@as string]], url --[[@as string]])
		if not pkg and not isOffline then
			-- A src rock without its rockspec is not a valid cache entry: a killed run
			-- or a directory another process retired leaves one behind, and trusting it
			-- fails every later run. Drop it and materialize once more.
			util.retireCacheDir(archiveDir --[[@as string]])
			archiveDir = lde.global.getOrInitArchive(url --[[@as string]], isOffline)
			pkg, err = util.openSrcRock(archiveDir --[[@as string]], url --[[@as string]])
		end
		if not pkg then
			return nil, nil, "Failed to load src rock '" .. name .. "': " .. (err or "")
		end

		---@type lde.Lockfile.ArchiveDependency
		const lockEntry = { archive = url } --[[@as lde.Lockfile.ArchiveDependency]]
		return pkg, lockEntry
	end

	return util.openRockspecUrl(name, url --[[@as string]], nil, nil, isOffline)
end

---@return luarocks.Manifest?, string?
function util.getManifest()
	return getManifest()
end

---@param url string
function util.rockspecCacheFile(url)
	return path.join(lde.global.getRockspecCacheDir(), (url:gsub("[^%w]", "_")))
end

--- Monorepo support: lde.json can live anywhere in the tree.
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

--- Removes a cache directory without ever exposing a half-deleted tree to another
--- process: the recursive delete happens on a private name after an atomic rename.
--- Readers then see either the old tree or none at all, so a concurrent run can
--- re-materialize instead of scanning a partially emptied directory (which is how
--- "No rockspec found in src rock" happens).
---@param dir string
function util.retireCacheDir(dir)
	if not fs.isdir(dir) then return end
	const retired = dir .. ".retired-" .. (tostring({}):match("0x(%x+)$") or tostring(os.time()))
	if fs.move(dir, retired) then
		fs.rmdir(retired)
		return
	end
	-- A reader holds it open (Windows) or the rename crossed devices: delete in
	-- place as a last resort rather than leaving the cache entry behind.
	fs.rmdir(dir)
end

--- A .src.rock holds the rockspec plus either an unpacked tree or a nested archive; the nested archive is authoritative and extracted over stray subdirs from interrupted runs.
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
		-- Extract into a temp dir and move it in: an interrupted extract must not
		-- leave a tree that later runs trust (same rule as the archive cache).
		const marker = path.join(dir, ".lde-complete")
		-- Extract into a temp dir and move it in: an interrupted extract must not
		-- leave a tree that later runs trust. A dir already in place is adopted
		-- (same rule as the archive cache) rather than deleted, which would race
		-- with a process extracting it right now.
		if fs.isdir(dir) and not fs.exists(marker) then fs.write(marker, "") end
		if not fs.isdir(dir) then
			const tmpDir = dir .. ".tmp" .. tostring({}):match("0x(%x+)$")
			const ok2, err2 = Archive().new(nestedArchive):extract(tmpDir, { stripComponents = true })
			if not ok2 then
				fs.rmdir(tmpDir)
				return nil, nil, "Failed to extract nested archive in src rock: " .. (err2 or "")
			end
			if not fs.move(tmpDir, dir) then
				fs.rmdir(tmpDir)
				if not fs.isdir(dir) then
					return nil, nil, "Failed to move nested archive into " .. dir
				end
			end
			fs.write(marker, "")
		end
		srcDir = dir
	end

	return srcDir or archiveDir, rockspecPath, nil
end

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
