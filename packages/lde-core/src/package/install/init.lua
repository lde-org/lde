local fs = require("fs")
local path = require("path")
local util = require("util")
local ansi = require("ansi")
local rocked = require("rocked")
local download = require("lde-core.util.download")

local lde = require("lde-core")

--- Copies config-only flags (optional, features) from a config entry onto a lock entry.
---@param lockEntry lde.Lockfile.Dependency
---@param depInfo lde.Package.Config.Dependency
---@return lde.Lockfile.Dependency
local function withConfigFlags(lockEntry, depInfo)
	lockEntry.optional = depInfo.optional
	lockEntry.features = depInfo.features
	return lockEntry
end

---@class lde.install.Context
---@field relativeTo string
---@field stack table<string, { pkg: lde.Package, lock: lde.Lockfile.Dependency }>
---@field rootLockfile lde.Lockfile?

--- Returns a string key that uniquely identifies a dependency's source.
---@param entry lde.Lockfile.Dependency
---@param pkg lde.Package
---@return string
local function sourceKey(entry, pkg)
	if entry.git then return "git:" .. entry.git .. "@" .. (entry.commit or "") end
	if entry.path then return "path:" .. pkg.dir end
	if entry.archive then return "archive:" .. entry.archive end
	return "unknown"
end

--- Applies the root lockfile pin to a dependency entry, if present.
---@param ctx lde.install.Context
---@param alias string
---@param depInfo lde.Package.Config.Dependency
---@return lde.Package.Config.Dependency
local function applyLock(ctx, alias, depInfo)
	if ctx.rootLockfile then
		local locked = ctx.rootLockfile:getDependency(alias)
		if locked then depInfo = withConfigFlags(locked, depInfo) end
	end
	return depInfo
end

--- Approximate source key for a not-yet-materialized dependency, used to detect
--- conflicting sources when the same alias is requested from different places.
---@param alias string
---@param depInfo lde.Package.Config.Dependency
---@param relativeTo string
---@return string
local function depSourceKey(alias, depInfo, relativeTo)
	depInfo = depInfo or {}
	if depInfo.path then
		return "path:" .. path.resolve(relativeTo, path.normalize(depInfo.path))
	elseif depInfo.git then
		return "git:" .. depInfo.git .. "@" .. (depInfo.commit or "")
	elseif depInfo.archive then
		return "archive:" .. depInfo.archive
	elseif depInfo.luarocks then
		-- Resolve to the concrete version so two parents with different
		-- constraints that land on the same version don't conflict.
		local name = depInfo.name or depInfo.luarocks
		local constraint = depInfo.version or ""
		local v = lde.util.resolveLuarocksBest(name, constraint)
		return "luarocks:" .. name .. "@" .. (v or constraint)
	elseif depInfo.version then
		return "registry:" .. (depInfo.name or alias) .. "@" .. (depInfo.version or "")
	end
	return "unknown"
end

-- ── Dependency nodes ──────────────────────────────────────────────────────
--
-- During the two-phase install every dependency becomes a "node": a plain
-- table recording what the dependency is and how far it has progressed.
-- The graph walk (collectDependencies) drives nodes through:
--
--   1. metadata   — fetch the tiny published rockspec to learn its deps
--   2. content    — download the artifact (.src.rock / tarball / archive)
--   3. consume    — make its dependency list available (expand the graph)
--   4. materialize + open — extract, open the package, emit its lock entry
--
-- Per-kind behavior lives in `handlers` below; the node itself only carries
-- data. Node fields:
--   alias, depInfo, kind, relativeTo, sourceKey
--   metadata       (luarocks) rockspec fetch needed before deps are known
--   rockspecUrl/rockspecFile, version, srcUrl, spec
--   expandAfter    deps only knowable after content downloads (git/archive/
--                  pinned deps, or luarocks versions without a published rockspec)
--   gitPlan, repoName, deps, pkg, expandDir, _content, _fallbackGit

--- Resolve a luarocks dependency to its version + metadata/content URLs.
---@param alias string
---@param depInfo lde.Package.Config.LuarocksDependency
---@return table node
local function makeLuarocksNode(alias, depInfo)
	local name = depInfo.name or depInfo.luarocks -- the luarocks package name (alias may differ)
	local version, rockspecUrl, srcUrl, err = lde.util.resolveLuarocksBest(name, depInfo.version)
	if not version then
		error("Failed to resolve luarocks dep '" .. alias .. "': " .. (err or ""))
	end

	return {
		alias = alias,
		depInfo = depInfo,
		kind = "luarocks",
		relativeTo = "",
		name = name,
		version = version,
		sourceKey = "luarocks:" .. name .. "@" .. version,
		metadata = rockspecUrl ~= nil,
		rockspecUrl = rockspecUrl,
		rockspecFile = rockspecUrl and lde.util.rockspecCacheFile(rockspecUrl) or nil,
		srcUrl = srcUrl, -- preferred content artifact; nil when no src rock exists
		expandAfter = not rockspecUrl, -- without a rockspec the deps come from the content
	}
end

--- Creates a node for a dependency, honoring lockfile pins.
---@param alias string
---@param depInfo lde.Package.Config.Dependency
---@param relativeTo string
---@param ctx lde.install.Context
---@return table node
local function makeNode(alias, depInfo, relativeTo, ctx)
	depInfo = applyLock(ctx, alias, depInfo)

	if depInfo.path then
		local dir = path.resolve(relativeTo, path.normalize(depInfo.path))
		return {
			alias = alias,
			depInfo = depInfo,
			kind = "path",
			relativeTo = relativeTo,
			dir = dir,
			sourceKey = "path:" .. dir,
		}
	elseif depInfo.git then
		local gitPlan = lde.global.planGitRepo(alias, depInfo.git, depInfo.branch, depInfo.commit)
		return {
			alias = alias,
			depInfo = depInfo,
			kind = "git",
			relativeTo = relativeTo,
			sourceKey = "git:" .. depInfo.git .. "@" .. (gitPlan.commit or ""),
			repoName = alias,
			gitPlan = gitPlan,
			expandAfter = true, -- monorepo: lde.json location unknown until extracted
		}
	elseif depInfo.archive then
		return {
			alias = alias,
			depInfo = depInfo,
			kind = "archive",
			relativeTo = relativeTo,
			sourceKey = "archive:" .. depInfo.archive,
			expandAfter = true, -- deps only known from the extracted content
		}
	elseif depInfo.luarocks then
		return makeLuarocksNode(alias, depInfo)
	elseif depInfo.version then
		-- Registry packages are git repos (same resolution as a git dep).
		local packageName = depInfo.name or alias
		lde.global.syncRegistry()
		local portfile, err = lde.global.lookupRegistryPackage(packageName)
		if not portfile then
			error("Registry lookup failed for '" .. alias .. "': " .. err)
		end
		local _, commit = lde.global.resolveRegistryVersion(portfile, depInfo.version)
		local gitPlan = lde.global.planGitRepo(packageName, portfile.git, portfile.branch, commit)
		return {
			alias = alias,
			depInfo = depInfo,
			kind = "git",
			relativeTo = relativeTo,
			sourceKey = "git:" .. portfile.git .. "@" .. commit,
			repoName = packageName,
			gitPlan = gitPlan,
			expandAfter = true,
		}
	else
		error("Unsupported dependency type for: " .. alias)
	end
end

-- ── Per-kind behavior ─────────────────────────────────────────────────────
---@type table<string, table>
local handlers = {}

--- Shared helpers dispatching on node.kind.
local function h(n) return handlers[n.kind] end
local function content(n) return h(n).content(n) end

--- Make the node's dependency list available (idempotent).
local function consume(n)
	if n.deps then return end
	h(n).consume(n)
end

--- Extract the node's downloaded content (after the batch drained).
local function materialize(n)
	h(n).materialize(n, content(n))
end

--- Open the node's package (requires content materialized).
local function open(n)
	if n.pkg then return n.pkg end
	h(n).open(n)
	return n.pkg
end

--- Emit the lockfile entry for this node.
local function lock(n)
	return h(n).lock(n)
end

--- Standard consume for content-based kinds: open the package, read its deps.
local function consumeFromPkg(n)
	open(n)
	n.deps = n.pkg:readConfig().dependencies or {}
end

--- Expand a node's deps into the graph; returns newly created nodes.
---@param n table
---@param ctx lde.install.Context
---@param graph table
---@param order table
---@return table[]
local function expand(n, ctx, graph, order)
	local newNodes = {}
	for alias, depInfo in pairs(n.deps or {}) do
		if not graph[alias] then
			local node = makeNode(alias, depInfo, n.expandDir or ctx.relativeTo, ctx)
			graph[alias] = node
			order[#order + 1] = node
			newNodes[#newNodes + 1] = node
		else
			-- Same alias requested again from a different place: verify the
			-- sources match (e.g. two different path deps under one name).
			local effective = applyLock(ctx, alias, depInfo)
			local existingKey = graph[alias].sourceKey
			local newKey = depSourceKey(alias, effective, n.expandDir or ctx.relativeTo)
			if existingKey ~= newKey then
				error("Conflicting sources for dependency '" .. alias .. "':\n  " .. existingKey .. "\n  " .. newKey)
			end
		end
	end
	return newNodes
end

--- path: local directory, already on disk.
handlers.path = {
	content = function() return nil end,
	materialize = function() end,
	open = function(n)
		local pkg, err = lde.Package.open(n.dir, n.depInfo.rockspec)
		if not pkg then
			error("Failed to load local dependency package for: " .. n.alias .. "\nError: " .. err)
		end
		n.pkg = pkg
		n.expandDir = pkg:getDir()
	end,
	consume = function(n)
		consumeFromPkg(n)
	end,
	lock = function(n)
		return { path = n.depInfo.path, name = n.depInfo.name, rockspec = n.depInfo.rockspec }
	end,
}

--- git (and registry): tarball content, package/deps found after extraction.
handlers.git = {
	content = function(n)
		local g = n.gitPlan
		if g.tarballUrl then
			return { url = g.tarballUrl, file = g.archiveFile, dir = g.dir, kind = "git" }
		elseif g.clone then
			return { kind = "clone" } -- unrecognized host: git clone directly
		end
		return nil -- already cached
	end,
	materialize = function(n, c)
		if c.kind == "clone" then
			local ok, err = lde.global.cloneDir(n.gitPlan.clone.repoName, n.gitPlan.clone.repoUrl, n.gitPlan.clone.commit)
			if not ok then error("Failed to clone git repository: " .. (err or "unknown error")) end
			return
		end
		local res = download.result(c.file)
		if res and not res.ok then error("Failed to download " .. c.url .. ": " .. (res.err or "")) end
		local ok, err = lde.global.extractGitTarball(c.file, c.dir)
		if not ok then error("Failed to extract " .. n.repoName .. ": " .. (err or "")) end
	end,
	open = function(n)
		local pkg, err = lde.util.findNamedPackage(n.gitPlan.dir, n.repoName, n.depInfo.rockspec)
		if not pkg then error(err or "No package found in git repository") end
		n.pkg = pkg
		n.expandDir = pkg:getDir()
	end,
	consume = function(n)
		consumeFromPkg(n)
	end,
	lock = function(n)
		return {
			git = n.depInfo.git,
			commit = n.gitPlan.commit,
			branch = n.depInfo.branch,
			name = n.depInfo.name,
			rockspec = n.depInfo.rockspec,
		}
	end,
}

--- archive: URL downloads into the tar cache, then the rockspec is found inside.
handlers.archive = {
	content = function(n)
		local dir = lde.global.getArchiveDir(n.depInfo.archive)
		return { url = n.depInfo.archive, file = dir .. ".archive", dir = dir, kind = "archive" }
	end,
	materialize = function(n, c)
		local res = download.result(c.file)
		if res and not res.ok then error("Failed to download archive '" .. c.url .. "': " .. (res.err or "")) end
		local ok, err = lde.global.extractArchive(c.url, c.file, c.dir)
		if not ok then error("Failed to extract archive '" .. c.url .. "': " .. (err or "")) end
	end,
	open = function(n)
		local c = content(n)
		-- .src.rock archives contain a rockspec + possibly a source subdir
		local pkgDir, rockspecPath = c.dir, n.depInfo.rockspec
		if n.depInfo.archive:match("%.src%.rock$") and not n.depInfo.rockspec then
			local iter = fs.readdir(c.dir)
			if iter then
				for entry in iter do
					if entry.type == "file" and entry.name:match("%.rockspec$") then
						rockspecPath = path.join(c.dir, entry.name)
					elseif entry.type == "dir" and pkgDir == c.dir then
						pkgDir = path.join(c.dir, entry.name)
					end
				end
			end
		end
		local pkg, err = lde.Package.open(pkgDir, rockspecPath)
		if not pkg then error("Failed to load archive dependency '" .. n.alias .. "': " .. (err or "")) end
		n.pkg = pkg
		n.expandDir = pkg:getDir()
	end,
	consume = function(n)
		consumeFromPkg(n)
	end,
	lock = function(n)
		return { archive = n.depInfo.archive, name = n.depInfo.name, rockspec = n.depInfo.rockspec }
	end,
}

--- luarocks: metadata is the published rockspec; content prefers the .src.rock
--- and falls back to the rockspec's own source artifact.
handlers.luarocks = {
	content = function(n)
		if n._content then return n._content end

		if n.srcUrl then
			local dir = lde.global.getArchiveDir(n.srcUrl)
			n._content = { url = n.srcUrl, file = dir .. ".archive", dir = dir, kind = "src" }
			return n._content
		end

		-- No src rock for this version: fall back to the rockspec's source.
		consume(n)
		local source = n.spec and n.spec.source
		if not source or not source.url then
			error("No source artifact for '" .. n.alias .. "'")
		end
		local sourceUrl = source.url
		if sourceUrl:match("^git") then
			sourceUrl = lde.util.normalizeGitUrl(sourceUrl)
			n._fallbackGit = lde.global.planGitRepo(n.name, sourceUrl, source.branch or source.tag, nil)
			n._fallbackGit.url = sourceUrl
			if n._fallbackGit.tarballUrl then
				n._content = {
					url = n._fallbackGit.tarballUrl,
					file = n._fallbackGit.archiveFile,
					dir = n._fallbackGit.dir,
					kind = "git",
				}
			else
				n._content = { kind = "clone" }
			end
		else
			local dir = lde.global.getArchiveDir(sourceUrl)
			n._content = { url = sourceUrl, file = dir .. ".archive", dir = dir, kind = "archive" }
		end
		return n._content
	end,
	materialize = function(n, c)
		if c.kind == "clone" then
			local ok, err = lde.global.cloneDir(
				n._fallbackGit.clone.repoName, n._fallbackGit.clone.repoUrl, n._fallbackGit.clone.commit)
			if not ok then error("Failed to clone git repository: " .. (err or "unknown error")) end
			return
		end
		local res = download.result(c.file)
		if res and not res.ok then error("Failed to download " .. c.url .. ": " .. (res.err or "")) end
		local ok, err = lde.global.extractArchive(c.url, c.file, c.dir)
		if not ok then error("Failed to extract '" .. (c.url or c.dir) .. "': " .. (err or "")) end
	end,
	consume = function(n)
		if n.rockspecFile and fs.exists(n.rockspecFile) then
			local content = fs.read(n.rockspecFile)
			local ok, spec = rocked.parse(content)
			if not ok then
				error("Failed to parse rockspec '" .. tostring(n.rockspecUrl) .. "': " .. tostring(spec))
			end
			n.spec = spec
			n.deps = {}
			for _, depStr in ipairs(spec.dependencies or {}) do
				local name, rest = depStr:match("^([%w%-_]+)%s*(.*)")
				if name and name ~= "lua" and name ~= "luajit" then
					n.deps[name] = { luarocks = name, version = rest ~= "" and rest or nil }
				end
			end
		elseif n.srcUrl then
			-- No published rockspec: read deps from the extracted content.
			local pkg = open(n)
			n.deps = pkg:readConfig().dependencies or {}
		else
			error("Missing rockspec for '" .. n.alias .. "': " .. tostring(n.rockspecUrl))
		end
	end,
	open = function(n)
		local c = content(n)
		local pkg, err
		if c.kind == "src" then
			pkg, err = lde.util.openSrcRock(c.dir, c.url)
		else
			pkg, err = lde.Package.openRockspec(c.dir, n.rockspecUrl)
		end
		if not pkg then error("Failed to load '" .. n.name .. "': " .. (err or "")) end
		n.pkg = pkg
		n.expandDir = pkg:getDir()
	end,
	lock = function(n)
		local c = content(n)
		if c.kind == "src" then
			return { archive = n.srcUrl }
		end
		if c.kind == "git" or c.kind == "clone" then
			return { git = n._fallbackGit.url, commit = n._fallbackGit.commit, rockspec = n.rockspecUrl }
		end
		return { archive = c.url, rockspec = n.rockspecUrl }
	end,
}

--- Resolves the whole dependency graph onto `ctx.stack`.
---
--- Two-phase design: the graph is walked by fetching only small metadata
--- (published rockspecs) in parallel batches, then all content artifacts
--- (.src.rock files, source tarballs) are downloaded in one parallel batch,
--- and finally everything is extracted and opened. Git deps (and lockfile-
--- pinned archives) are the exception: their metadata lives inside the repo,
--- so their content is downloaded during the walk and they expand after it.
---
---@param dependencies table<string, lde.Package.Config.Dependency>
---@param ctx lde.install.Context
local function collectDependencies(dependencies, ctx)
	local graph = {} -- alias -> node
	local order = {} -- nodes in discovery order

	local function addDeps(deps, relativeTo)
		local newNodes = {}
		for alias, depInfo in pairs(deps) do
			if not graph[alias] then
				local node = makeNode(alias, depInfo, relativeTo, ctx)
				graph[alias] = node
				order[#order + 1] = node
				newNodes[#newNodes + 1] = node
			else
				-- Same alias requested again from a different place: verify the
				-- sources match (e.g. two different path deps under one name).
				local effective = applyLock(ctx, alias, depInfo)
				local existingKey = graph[alias].sourceKey
				local newKey = depSourceKey(alias, effective, relativeTo)
				if existingKey ~= newKey then
					error("Conflicting sources for dependency '" .. alias .. "':\n  " .. existingKey .. "\n  " .. newKey)
				end
			end
		end
		return newNodes
	end

	-- ── Phase 1: graph walk (metadata-only) ────────────────────────────────
	local frontier = addDeps(dependencies, ctx.relativeTo)

	while #frontier > 0 do
		local nextFrontier = {}
		local metaBatch = {}
		local contentBatch = {}

		for _, node in ipairs(frontier) do
			local hnd = h(node)

			if hnd.metadata then
				-- Fetch the published rockspec (tiny) to discover deps.
				if not fs.exists(node.rockspecFile) then
					download.prefetch(node.rockspecUrl, node.rockspecFile)
				end
				metaBatch[#metaBatch + 1] = node
			elseif not node.expandAfter and not content(node) then
				-- path deps: nothing to download, consume and expand immediately.
				consume(node)
				for _, child in ipairs(expand(node, ctx, graph, order)) do
					nextFrontier[#nextFrontier + 1] = child
				end
			end

			if node.expandAfter then
				-- Git deps / pinned archives: content is needed to expand.
				local c = content(node)
				if c and not fs.exists(c.dir) then
					download.prefetch(c.url, c.file)
					contentBatch[#contentBatch + 1] = node
				end
			end
		end

		download.drain()

		for _, node in ipairs(metaBatch) do
			consume(node)
			for _, child in ipairs(expand(node, ctx, graph, order)) do
				nextFrontier[#nextFrontier + 1] = child
			end
		end

		for _, node in ipairs(contentBatch) do
			materialize(node)
			consume(node)
			for _, child in ipairs(expand(node, ctx, graph, order)) do
				nextFrontier[#nextFrontier + 1] = child
			end
		end

		frontier = nextFrontier
	end

	-- ── Phase 2: download all remaining content in one parallel batch ──────
	local contentNodes = {}
	for _, node in ipairs(order) do
		local c = content(node)
		if c and not fs.exists(c.dir) then
			download.prefetch(c.url, c.file)
			contentNodes[#contentNodes + 1] = node
		end
	end
	download.drain()
	for _, node in ipairs(contentNodes) do
		materialize(node)
	end

	-- ── Phase 3: open packages + build the stack ───────────────────────────
	for _, node in ipairs(order) do
		local alias = node.alias
		local pkg = open(node)
		local lockEntry = lock(node)
		lockEntry.name = node.depInfo.name

		if ctx.stack[alias] then
			local existingKey = sourceKey(ctx.stack[alias].lock, ctx.stack[alias].pkg)
			local newKey = sourceKey(lockEntry, pkg)
			if existingKey ~= newKey then
				error("Conflicting sources for dependency '" .. alias .. "':\n  " .. existingKey .. "\n  " .. newKey)
			end
		else
			ctx.stack[alias] = { pkg = pkg, lock = withConfigFlags(lockEntry, node.depInfo) }
		end
	end
end

---@type table<string, lde.Package.Config.FeatureFlag>
local platformLookup = { Windows = "windows", Linux = "linux", OSX = "macos" }

--- Resolves which optional deps are enabled given a feature list + current platform.
---@param pkg lde.Package
---@param features lde.Package.Config.FeatureFlag[]
---@return table<string, true>
local function resolveEnabledOptional(pkg, features)
	local enabled = {}

	local featureDefs = pkg:readConfig().features
	if not featureDefs then return enabled end

	for _, flag in ipairs(features) do
		local deps = featureDefs[flag]
		if deps then
			for _, depName in ipairs(deps) do enabled[depName] = true end
		end
	end

	return enabled
end

--- Saves the lockfile and writes the .installed hash marker.
---@param pkg lde.Package
---@param stack table<string, { pkg: lde.Package, lock: lde.Lockfile.Dependency }>
---@param modulesDir string
local function commitLockfile(pkg, stack, modulesDir)
	local lockEntries = {}
	for alias, entry in pairs(stack) do
		lockEntries[alias] = entry.lock
	end

	local lockfile = lde.Lockfile.new(pkg:getLockfilePath(), lockEntries)
	lockfile:save()

	local content = assert(fs.read(pkg:getLockfilePath()), "Failed to read " .. pkg:getLockfilePath())
	fs.write(path.join(modulesDir, ".installed"), util.fnv1a(content))
end

---@param package lde.Package
---@param dependencies table<string, lde.Package.Config.Dependency>?
---@param relativeTo string?
---@param features lde.Package.Config.FeatureFlag[]?
local function installDependencies(package, dependencies, relativeTo, features)
	local isRoot = dependencies == nil
	dependencies = dependencies or package:getDependencies()
	relativeTo = relativeTo or package.dir

	features = features or {}
	features[#features + 1] = platformLookup[jit.os]

	local modulesDir = package:getModulesDir()

	-- Fast path: if target/.installed hash matches the current lockfile, skip all work
	if isRoot then
		local installedPath = path.join(modulesDir, ".installed")
		local lockfilePath = package:getLockfilePath()
		if fs.exists(lockfilePath) and fs.exists(installedPath) then
			local content = fs.read(lockfilePath)
			if content and fs.read(installedPath) == util.fnv1a(content) then return end
		end
	end

	if not fs.exists(modulesDir) then fs.mkdir(modulesDir) end

	local ctx = {
		relativeTo = relativeTo,
		stack = {},
		rootLockfile = isRoot and package:readLockfile() or nil
	}

	-- Parallel download session: sources are prefetched in batches during the
	-- graph walk and materialized afterwards. Always cleaned up, even on error.
	local bar = lde.verbose and ansi.progress("Downloading dependencies") or nil
	download.begin(bar and {
		progress = function(done, total)
			local ratio = total > 0 and (done / total) or nil
			bar:update(ratio, done .. "/" .. total)
		end
	} or nil)

	local ok, err = pcall(collectDependencies, dependencies, ctx)
	if ok then
		download.finish()
		if bar then bar:done() end
	else
		download.abort()
		if bar then bar:fail() end
		error(err)
	end

	-- Gets which features are enabled (+ OS specific features)
	local enabledOptional = resolveEnabledOptional(package, features)

	for alias, entry in pairs(ctx.stack) do
		local depInfo = dependencies[alias]

		-- Optional, skip..
		if depInfo and depInfo.optional and not enabledOptional[alias] then
			goto continue
		end

		local dest = path.join(modulesDir, alias)

		-- Has a build script, needs to run.
		if not fs.islink(dest) then
			entry.pkg:build(dest)
		end

		::continue::
	end

	if isRoot then
		commitLockfile(package, ctx.stack, modulesDir)
	end
end

return installDependencies
