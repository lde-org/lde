local util = {}

local fs = require("fs")
local path = require("path")
local json = require("json")
local rocked = require("rocked")
local ansi = require("ansi")
local lde = require("lde-core")
local luarocks = require("luarocks")
local curl = require("curl-sys")
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
	local res, err = curl.get(MANIFEST_URL)
	if not res then
		if p then p:fail() end
		return nil, "Failed to fetch manifest: " .. (err or "")
	end

	fs.write(cacheFile, res.body)
	cachedManifest = luarocks.Manifest.new(res.body)
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
		local res, fetchErr = curl.get(url)
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

--- Whether a Lua-version constraint string (e.g. "== 5.4", ">= 5.1, < 5.4",
--- "5.1") is satisfied by the given version.
---@param constraintStr string
---@param ver string
---@return boolean
local function constraintSatisfied(constraintStr, ver)
	if not constraintStr or constraintStr == "" then return true end
	local found = false
	for op, cver in constraintStr:gmatch("([><=~!]+)%s*([%d%.%-]+)") do
		found = true
		if not luarocks.satisfies(ver, op, cver) then return false end
	end
	if not found then
		return luarocks.satisfies(ver, "==", constraintStr)
	end
	return true
end

--- Whether a rockspec's lua/luajit dependency constraints accept the running
--- engine (LuaJIT 2.1 == Lua 5.1). Rocks like cqueues publish per-version
--- variants (…-51 through …-54) and must resolve to the 5.1 build.
---@param content string
---@return boolean
local function rockspecEngineOkContent(content)
	local ok, spec = rocked.parse(content)
	if not ok then return true end
	for _, depStr in ipairs(spec.dependencies or {}) do
		local name, rest = depStr:match("^([%w%-_]+)%s*(.*)")
		if name == "lua" then
			if not constraintSatisfied(rest, "5.1") then return false end
		elseif name == "luajit" then
			if not constraintSatisfied(rest, "2.1") then return false end
		end
	end
	return true
end

--- Fetch (or read from the rockspec cache) a published rockspec and check its
--- engine constraints. Unverifiable rockspecs are assumed compatible.
---@param url string
---@return boolean
local function rockspecEngineOk(url)
	local cacheFile = util.rockspecCacheFile(url)
	local content = fs.exists(cacheFile) and fs.read(cacheFile) or nil
	if not content then
		local res, err = curl.get(url)
		if not res then return true end
		content = res.body
		fs.write(cacheFile, content)
	end
	return rockspecEngineOkContent(content)
end

--- Resolves the best version of a luarocks package plus the rockspec (metadata)
--- and .src.rock (content) URLs for that exact version. Uses the persisted URL
--- cache when possible; falls back to a manifest scan otherwise.
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
			-- The URL cache may predate engine-aware resolution; skip entries
			-- the current engine can't run (e.g. a Lua 5.4-only build).
			if not rockspecUrl or rockspecEngineOk(rockspecUrl) then
				if arch == "src" then
					return version, rockspecUrl, url
				end
				return version, url, nil
			end
		end
	end

	local manifest, err = getManifest()
	if not manifest then return nil, nil, nil, err end

	-- Walk candidate versions newest-first and skip any whose rockspec declares
	-- an engine (lua/luajit) constraint the current engine doesn't satisfy.
	local candidates = luarocks.listBest(manifest, name, constraint)
	local v, rockspecUrl, srcUrl
	for _, c in ipairs(candidates) do
		if not (c.rockspecUrl and not rockspecEngineOk(c.rockspecUrl)) then
			v, rockspecUrl, srcUrl = c.version, c.rockspecUrl, c.srcUrl
			break
		end
	end
	if not v then
		return nil, nil, nil, "No version of '" .. name .. "'" ..
			(constraint and (" satisfies: " .. constraint) or "") ..
			" is compatible with the current engine (LuaJIT / Lua 5.1)"
	end

	-- Cache unversioned resolutions for future invocations
	if not constraint then
		cache[name] = { url = srcUrl or rockspecUrl, arch = srcUrl and "src" or "rockspec" }
		saveUrlCache()
	end

	return v, rockspecUrl, srcUrl, nil
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

--- Opens the package inside an extracted .src.rock archive: finds the rockspec,
--- a source subdir, and any nested archive (extracting it if needed).
---@param archiveDir string
---@param url string
---@return lde.Package?, string?
function util.openSrcRock(archiveDir, url)
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
		return nil, "No rockspec found in src rock for '" .. (url or "?") .. "'"
	end

	-- If no subdir was found but a nested archive was, extract it now.
	if not srcDir and nestedArchive then
		srcDir = nestedArchive:gsub("%.tar%.[gbx]z2?$", ""):gsub("%.zip$", "")
		if not fs.isdir(srcDir) then
			fs.mkdir(srcDir)
			local ok2, err2 = Archive.new(nestedArchive):extract(srcDir, { stripComponents = true })
			if not ok2 then
				return nil, "Failed to extract nested archive in src rock: " .. (err2 or "")
			end
		end
	end

	return lde.Package.openRockspec(srcDir or archiveDir, rockspecPath)
end

return util
