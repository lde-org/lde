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
---@field locked boolean? # --locked: fail when a dep isn't pinned in the lockfile
---@field downloads integer # content artifacts actually downloaded (0 = nothing to fetch)
---@field builds integer # build scripts actually run (0 = nothing to compile)

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
		if locked then return withConfigFlags(locked, depInfo) end
	end
	-- --locked installs: the lockfile must already pin every non-path dependency.
	-- Failing loudly instead of resolving a fresh commit/version is what keeps
	-- `lde sync --locked` reproducible and offline.
	if ctx.locked and not depInfo.path then
		error("Lockfile is out of date: '" .. alias .. "' is not pinned. Run `lde sync` to update it.")
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
		-- The commit is a deterministic resolution detail (lsRemote HEAD or lockfile
		-- pin), so the source identity is the URL alone — a re-request of the same
		-- repo from a different parent must not false-conflict on an unresolved
		-- vs resolved commit.
		return "git:" .. depInfo.git
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
-- data.

---@class lde.install.ContentPlan
---@field kind "src"|"git"|"archive"|"clone"
---@field url string?  -- download source (nil for the git-clone fallback)
---@field file string? -- local cache file to download into (nil for clone)
---@field dir string?  -- extraction target (nil for clone / cached git)

---@class lde.install.GitPlan
---@field dir string
---@field commit string
---@field tarballUrl string?
---@field archiveFile string?
---@field url string? -- normalized source URL (set on luarocks fallback plans)
---@field clone { repoName: string, repoUrl: string, commit: string }?

---@class lde.install.Node
---@field alias string -- key in the parent's dependencies table
---@field depInfo lde.Package.Config.Dependency
---@field kind "path"|"git"|"archive"|"luarocks"
---@field sourceKey string -- identity used for conflict detection
---@field dir string? -- path deps: resolved directory
---@field repoName string? -- git/registry: package name to find inside the repo
---@field metadata boolean? -- luarocks: fetch the published rockspec for deps
---@field rockspecUrl string?
---@field rockspecFile string?
---@field version string?
---@field srcUrl string? -- preferred content artifact (.src.rock)
---@field spec rocked.raw.Output?
---@field expandAfter boolean? -- deps only knowable after content downloads
---@field gitPlan lde.install.GitPlan?
---@field deps table<string, lde.Package.Config.Dependency>?
---@field pkg lde.Package?
---@field expandDir string? -- relativeTo base for the node's children
---@field materialized boolean? -- content already extracted/cloned this run
---@field _content lde.install.ContentPlan?
---@field _fallbackGit lde.install.GitPlan?

--- Resolve a luarocks dependency to its version + metadata/content URLs.
---@param alias string
---@param depInfo lde.Package.Config.LuarocksDependency
---@return lde.install.Node
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
---@return lde.install.Node
local function makeNode(alias, depInfo, relativeTo, ctx)
	depInfo = applyLock(ctx, alias, depInfo)

	if depInfo.path then
		local dir = path.resolve(relativeTo, path.normalize(depInfo.path))
		return {
			alias = alias,
			depInfo = depInfo,
			kind = "path",
			dir = dir,
			sourceKey = "path:" .. dir,
		}
	elseif depInfo.git then
		local gitPlan = lde.global.planGitRepo(alias, depInfo.git, depInfo.branch, depInfo.commit)
		return {
			alias = alias,
			depInfo = depInfo,
			kind = "git",
			sourceKey = "git:" .. depInfo.git,
			repoName = alias,
			gitPlan = gitPlan,
			expandAfter = true, -- monorepo: lde.json location unknown until extracted
		}
	elseif depInfo.archive then
		return {
			alias = alias,
			depInfo = depInfo,
			kind = "archive",
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
			sourceKey = "git:" .. portfile.git,
			repoName = packageName,
			gitPlan = gitPlan,
			expandAfter = true,
		}
	else
		error("Unsupported dependency type for: " .. alias)
	end
end

-- ── Per-kind behavior ─────────────────────────────────────────────────────
---@class lde.install.Handler
---@field content fun(node: lde.install.Node): lde.install.ContentPlan?
---@field materialize fun(node: lde.install.Node, content: lde.install.ContentPlan)
---@field consume fun(node: lde.install.Node)
---@field open fun(node: lde.install.Node)
---@field lock fun(node: lde.install.Node): lde.Lockfile.Dependency

---@type table<string, lde.install.Handler>
local handlers = {}

--- Shared helpers dispatching on node.kind.
---@param node lde.install.Node
---@return lde.install.Handler
local function h(node)
	return handlers[node.kind]
end

---@param node lde.install.Node
---@return lde.install.ContentPlan?
local function content(node)
	return h(node).content(node)
end

--- Make the node's dependency list available (idempotent).
---@param node lde.install.Node
local function consume(node)
	if node.deps then return end
	h(node).consume(node)
end

--- Extract the node's downloaded content (after the batch drained).
---@param node lde.install.Node
local function materialize(node)
	local c = content(node)
	assert(c, "no content plan for '" .. node.alias .. "'")
	h(node).materialize(node, c)
	node.materialized = true
end

--- Open the node's package (requires content materialized).
---@param node lde.install.Node
---@return lde.Package
local function open(node)
	if node.pkg then return node.pkg end
	h(node).open(node)
	---@cast node.pkg lde.Package
	return node.pkg
end

--- Emit the lockfile entry for this node.
---@param node lde.install.Node
---@return lde.Lockfile.Dependency
local function lock(node)
	return h(node).lock(node)
end

--- Standard consume for content-based kinds: open the package, read its deps.
---@param node lde.install.Node
local function consumeFromPkg(node)
	local pkg = open(node)
	node.deps = pkg:readConfig().dependencies or {}
end

--- Expand a node's deps into the graph; returns newly created nodes.
---@param node lde.install.Node
---@param ctx lde.install.Context
---@param graph table<string, lde.install.Node>
---@param order lde.install.Node[]
---@return lde.install.Node[]
local function expand(node, ctx, graph, order)
	---@type lde.install.Node[]
	local newNodes = {}
	for alias, depInfo in pairs(node.deps or {}) do
		if not graph[alias] then
			local newNode = makeNode(alias, depInfo, node.expandDir or ctx.relativeTo, ctx)
			graph[alias] = newNode
			order[#order + 1] = newNode
			newNodes[#newNodes + 1] = newNode
		else
			-- Same alias requested again from a different place: verify the
			-- sources match (e.g. two different path deps under one name).
			local effective = applyLock(ctx, alias, depInfo)
			local existingKey = graph[alias].sourceKey
			local newKey = depSourceKey(alias, effective, node.expandDir or ctx.relativeTo)
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
	---@param n lde.install.Node
	open = function(n)
		local pkg, err = lde.Package.open(n.dir, n.depInfo.rockspec)
		if not pkg then
			error("Failed to load local dependency package for: " .. n.alias .. "\nError: " .. err)
		end
		n.pkg = pkg
		n.expandDir = pkg:getDir()
	end,
	---@param n lde.install.Node
	consume = function(n)
		consumeFromPkg(n)
	end,
	---@param n lde.install.Node
	---@return lde.Lockfile.Dependency
	lock = function(n)
		return { path = n.depInfo.path, name = n.depInfo.name, rockspec = n.depInfo.rockspec }
	end,
}

--- git (and registry): tarball content, package/deps found after extraction.
handlers.git = {
	---@param n lde.install.Node
	---@return lde.install.ContentPlan?
	content = function(n)
		local g = n.gitPlan --[[@as lde.install.GitPlan]]
		if g.tarballUrl then
			return { url = g.tarballUrl, file = g.archiveFile, dir = g.dir, kind = "git" }
		elseif g.clone then
			return { kind = "clone" } -- unrecognized host: git clone directly
		end
		return nil -- already cached
	end,
	---@param n lde.install.Node
	---@param c lde.install.ContentPlan
	materialize = function(n, c)
		if c.kind == "clone" then
			local clone = n.gitPlan --[[@as lde.install.GitPlan]].clone --[[@as { repoName: string, repoUrl: string, commit: string }]]
			local ok, err = lde.global.cloneDir(clone.repoName, clone.repoUrl, clone.commit)
			if not ok then error("Failed to clone git repository: " .. (err or "unknown error")) end
			return
		end
		local res = download.result(c.file --[[@as string]])
		if res and not res.ok then error("Failed to download " .. c.url .. ": " .. (res.err or "")) end
		local ok, err = lde.global.extractGitTarball(c.file --[[@as string]], c.dir --[[@as string]])
		if not ok then error("Failed to extract " .. n.repoName .. ": " .. (err or "")) end
	end,
	---@param n lde.install.Node
	open = function(n)
		local gitPlan = n.gitPlan --[[@as lde.install.GitPlan]]
		local pkg, err = lde.util.findNamedPackage(gitPlan.dir, n.repoName, n.depInfo.rockspec)
		if not pkg then error(err or "No package found in git repository") end
		n.pkg = pkg
		n.expandDir = pkg:getDir()
	end,
	---@param n lde.install.Node
	consume = function(n)
		consumeFromPkg(n)
	end,
	---@param n lde.install.Node
	---@return lde.Lockfile.Dependency
	lock = function(n)
		local gitPlan = n.gitPlan --[[@as lde.install.GitPlan]]
		return {
			git = n.depInfo.git,
			commit = gitPlan.commit,
			branch = n.depInfo.branch,
			name = n.depInfo.name,
			rockspec = n.depInfo.rockspec,
		}
	end,
}

--- archive: URL downloads into the tar cache, then the rockspec is found inside.
handlers.archive = {
	---@param n lde.install.Node
	---@return lde.install.ContentPlan
	content = function(n)
		local dir = lde.global.getArchiveDir(n.depInfo.archive)
		return { url = n.depInfo.archive, file = dir .. ".archive", dir = dir, kind = "archive" }
	end,
	---@param n lde.install.Node
	---@param c lde.install.ContentPlan
	materialize = function(n, c)
		local res = download.result(c.file --[[@as string]])
		if res and not res.ok then error("Failed to download archive '" .. c.url .. "': " .. (res.err or "")) end
		local ok, err = lde.global.extractArchive(c.url --[[@as string]], c.file --[[@as string]], c.dir --[[@as string]])
		if not ok then error("Failed to extract archive '" .. c.url .. "': " .. (err or "")) end
	end,
	---@param n lde.install.Node
	open = function(n)
		local c = content(n) --[[@as lde.install.ContentPlan]]
		-- .src.rock archives contain a rockspec + possibly a source subdir
		local pkgDir, rockspecPath = c.dir, n.depInfo.rockspec
		if n.depInfo.archive:match("%.src%.rock$") and not n.depInfo.rockspec then
			local iter = fs.readdir(c.dir --[[@as string]])
			if iter then
				for entry in iter do
					if entry.type == "file" and entry.name:match("%.rockspec$") then
						rockspecPath = path.join(c.dir --[[@as string]], entry.name)
					elseif entry.type == "dir" and pkgDir == c.dir then
						pkgDir = path.join(c.dir --[[@as string]], entry.name)
					end
				end
			end
		end
		local pkg, err = lde.Package.open(pkgDir, rockspecPath)
		if not pkg then error("Failed to load archive dependency '" .. n.alias .. "': " .. (err or "")) end
		n.pkg = pkg
		n.expandDir = pkg:getDir()
	end,
	---@param n lde.install.Node
	consume = function(n)
		consumeFromPkg(n)
	end,
	---@param n lde.install.Node
	---@return lde.Lockfile.Dependency
	lock = function(n)
		return { archive = n.depInfo.archive, name = n.depInfo.name, rockspec = n.depInfo.rockspec }
	end,
}

--- luarocks: metadata is the published rockspec; content prefers the .src.rock
--- and falls back to the rockspec's own source artifact.
handlers.luarocks = {
	---@param n lde.install.Node
	---@return lde.install.ContentPlan?
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
		-- LuaRocks treats any of these as a git source: git://, git+https://,
		-- or a plain URL ending in .git (e.g. "https://github.com/x/y.git");
		-- anything else is a plain archive to download.
		if sourceUrl:match("^git") or sourceUrl:match("%.git$") then
			sourceUrl = lde.util.normalizeGitUrl(sourceUrl)
			local fallback = lde.global.planGitRepo(n.name, sourceUrl, source.branch or source.tag, nil)
			fallback.url = sourceUrl
			n._fallbackGit = fallback
			if fallback.tarballUrl then
				n._content = {
					url = fallback.tarballUrl,
					file = fallback.archiveFile,
					dir = fallback.dir,
					kind = "git",
				}
			elseif fallback.clone then
				n._content = { kind = "clone" }
			else
				-- Repo dir already cached: nothing to download or extract.
				n._content = nil
			end
		else
			local dir = lde.global.getArchiveDir(sourceUrl)
			n._content = { url = sourceUrl, file = dir .. ".archive", dir = dir, kind = "archive" }
		end
		return n._content
	end,
	---@param n lde.install.Node
	---@param c lde.install.ContentPlan
	materialize = function(n, c)
		if c.kind == "clone" then
			local fallback = n._fallbackGit --[[@as lde.install.GitPlan]]
			local clone = fallback.clone --[[@as { repoName: string, repoUrl: string, commit: string }]]
			local ok, err = lde.global.cloneDir(clone.repoName, clone.repoUrl, clone.commit)
			if not ok then error("Failed to clone git repository: " .. (err or "unknown error")) end
			return
		end
		local res = download.result(c.file --[[@as string]])
		if res and not res.ok then error("Failed to download " .. c.url .. ": " .. (res.err or "")) end
		local ok, err = lde.global.extractArchive(c.url --[[@as string]], c.file --[[@as string]], c.dir --[[@as string]])
		if not ok then error("Failed to extract '" .. (c.url or c.dir) .. "': " .. (err or "")) end
	end,
	---@param n lde.install.Node
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
				local name, version = rocked.parseDependency(depStr)
				if name and name ~= "lua" and name ~= "luajit" then
					n.deps[name] = { luarocks = name, version = version }
				end
			end
			-- Build backends (e.g. luarocks-build-rust-mlua) install alongside
			-- runtime deps so their modules resolve at build time.
			for _, depStr in ipairs(spec.build_dependencies or {}) do
				local name, version = rocked.parseDependency(depStr)
				if name and name ~= "lua" and name ~= "luajit" then
					n.deps[name] = { luarocks = name, version = version }
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
	---@param n lde.install.Node
	open = function(n)
		local c = content(n)
		local pkg, err
		if c and c.kind == "src" then
			pkg, err = lde.util.openSrcRock(c.dir --[[@as string]], c.url --[[@as string]])
		else
			-- Rockspec-backed, or a git fallback whose repo dir was already cached
			-- (content() returns nil in that case).
			local pkgDir = c and c.dir or (n._fallbackGit and n._fallbackGit.dir or n.dir)
			pkg, err = lde.Package.openRockspec(pkgDir, n.rockspecUrl)
		end
		if not pkg then error("Failed to load '" .. n.name .. "': " .. (err or "")) end
		n.pkg = pkg
		n.expandDir = pkg:getDir()
	end,
	---@param n lde.install.Node
	---@return lde.Lockfile.Dependency
	lock = function(n)
		local c = content(n)
		if c and c.kind == "src" then
			return { archive = n.srcUrl }
		end
		if c and (c.kind == "git" or c.kind == "clone") then
			local fallback = n._fallbackGit --[[@as lde.install.GitPlan]]
			return { git = fallback.url, commit = fallback.commit, rockspec = n.rockspecUrl }
		end
		if c then
			return { archive = c.url, rockspec = n.rockspecUrl }
		end
		-- Cached git dir (content() returns nil): lock to the resolved git ref.
		local fallback = n._fallbackGit --[[@as lde.install.GitPlan]]
		return { git = fallback.url, commit = fallback.commit, rockspec = n.rockspecUrl }
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
	---@type table<string, lde.install.Node>
	local graph = {} -- alias -> node
	---@type lde.install.Node[]
	local order = {} -- nodes in discovery order

	---@param deps table<string, lde.Package.Config.Dependency>
	---@param relativeTo string
	---@return lde.install.Node[]
	local function addDeps(deps, relativeTo)
		---@type lde.install.Node[]
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
	---@type lde.install.Node[]
	local frontier = addDeps(dependencies, ctx.relativeTo)

	while #frontier > 0 do
		---@type lde.install.Node[]
		local nextFrontier = {}
		---@type lde.install.Node[]
		local metaBatch = {}
		---@type lde.install.Node[]
		local contentBatch = {}

		for _, node in ipairs(frontier) do
			if node.metadata then
				-- Fetch the published rockspec (tiny) to discover deps.
				if not fs.exists(node.rockspecFile --[[@as string]]) then
					download.prefetch(node.rockspecUrl --[[@as string]], node.rockspecFile --[[@as string]])
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
				if (c and c.dir and not fs.exists(c.dir)) or (c and c.kind == "clone") then
					if c.kind ~= "clone" then
						download.prefetch(c.url --[[@as string]], c.file --[[@as string]])
					end
					ctx.downloads = ctx.downloads + 1
					contentBatch[#contentBatch + 1] = node
				else
					-- Content already cached: consume + expand without downloading.
					consume(node)
					for _, child in ipairs(expand(node, ctx, graph, order)) do
						nextFrontier[#nextFrontier + 1] = child
					end
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
	---@type lde.install.Node[]
	local contentNodes = {}
	for _, node in ipairs(order) do
		local c = content(node)
		-- Skip nodes whose content the walk already materialized (git clones
		-- have no cache dir to guard on, so without this they'd clone twice).
		if not node.materialized and ((c and c.dir and not fs.exists(c.dir)) or (c and c.kind == "clone")) then
			if c.kind ~= "clone" then
				download.prefetch(c.url --[[@as string]], c.file --[[@as string]])
			end
			ctx.downloads = ctx.downloads + 1
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

	-- Discovery order is a topological order (parents expand before their
	-- children), so the build pass can depend on it: build backends like
	-- luarocks-build-rust-mlua must land in target/ before the rock that
	-- requires them builds.
	ctx.order = order
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
	-- Merge with any existing lockfile: runtime and dev installs each commit
	-- their own slice of the graph, and neither should drop the other's pins.
	-- Copy into a fresh table: the json package iterates a decoded table's
	-- internal key order (maintained via json.addField), so mutating the
	-- decoded table directly would silently drop added entries on encode.
	local existing = pkg:readLockfile()
	local lockEntries = {}
	if existing then
		for alias, entry in pairs(existing:getDependencies()) do
			lockEntries[alias] = entry
		end
	end
	for alias, entry in pairs(stack) do
		lockEntries[alias] = entry.lock
	end

	local lockfile = lde.Lockfile.new(pkg:getLockfilePath(), lockEntries)
	lockfile:save()

	local content = assert(fs.read(pkg:getLockfilePath()), "Failed to read " .. pkg:getLockfilePath())
	-- Hash the lockfile together with the lde runtime version (binary upgrades
	-- invalidate the cache) and the manifest (a hand-edited lde.json must too),
	-- so the fast path only skips installs that are genuinely up to date.
	local manifest = fs.read(pkg:getConfigPath()) or ""
	fs.write(path.join(modulesDir, ".installed"),
		util.fnv1a(content .. "\n" .. tostring(lde.global.currentVersion) .. "\n" .. manifest))
end

---@param package lde.Package
---@param dependencies table<string, lde.Package.Config.Dependency>?
---@param relativeTo string?
---@param features lde.Package.Config.FeatureFlag[]?
---@param opts { summary: boolean?, locked: boolean? }?
---@return { checked: integer, installs: integer, changed: boolean, cached: boolean }
local function installDependencies(package, dependencies, relativeTo, features, opts)
	local isRoot = dependencies == nil
	dependencies = dependencies or package:getDependencies()
	relativeTo = relativeTo or package.dir
	opts = opts or {}

	features = features or {}
	features[#features + 1] = platformLookup[jit.os]

	local modulesDir = package:getModulesDir()

	-- Nothing to do (or already done): report the direct dep count so callers
	-- can still print a "No changes" summary line. cached = the install was a
	-- no-op because everything was already materialized.
	local function noopResult()
		local installs = 0
		for _ in pairs(dependencies) do installs = installs + 1 end
		return { checked = installs, installs = installs, changed = false, cached = true }
	end

	-- Temporary: a .skip marker in target/ (written by minilde during the
	-- bootstrap) means the deps are already materialized — skip all install
	-- work so nothing gets re-downloaded or re-built.
	if isRoot and fs.exists(path.join(modulesDir, ".skip")) then return noopResult() end

	-- Fast path: if target/.installed hash matches the current lockfile, skip all work.
	-- Bypassed under --locked so it always re-verifies the manifest against the
	-- lockfile instead of trusting the marker.
	if isRoot and not opts.locked then
		local installedPath = path.join(modulesDir, ".installed")
		local lockfilePath = package:getLockfilePath()
		if fs.exists(lockfilePath) and fs.exists(installedPath) then
			local content = fs.read(lockfilePath)
			-- commitLockfile hashes lockfile + runtime version + manifest; the
			-- check must use the same input or it can never match.
			local manifest = fs.read(package:getConfigPath()) or ""
			if content and fs.read(installedPath) == util.fnv1a(content .. "\n" .. tostring(lde.global.currentVersion) .. "\n" .. manifest) then
				return noopResult()
			end
		end
	end

	if not fs.exists(modulesDir) then fs.mkdir(modulesDir) end

	local ctx = {
		relativeTo = relativeTo,
		stack = {},
		-- The lockfile pins every previously-resolved alias (runtime and dev),
		-- so dev-dependency installs resolve from it instead of lsRemote-ing.
		rootLockfile = package:readLockfile(),
		locked = opts.locked,
		downloads = 0,
		builds = 0,
	}

	local installs = 0
	for _ in pairs(dependencies) do installs = installs + 1 end

	-- Parallel download session: sources are prefetched in batches during the
	-- graph walk and materialized afterwards. Always cleaned up, even on error.
	-- Only show the bar when there's something to download — packages with no
	-- dependencies shouldn't print a spurious "Downloading dependencies".
	local bar = lde.verbose and installs > 0
		and ansi.progress("Downloading dependencies") or nil
	download.begin(bar and {
		progress = function(done, total)
			local ratio = total > 0 and (done / total) or nil
			bar:update(ratio, done .. "/" .. total)
		end
	} or nil)

	local ok, err = pcall(collectDependencies, dependencies, ctx)
	if not ok then
		download.abort()
		-- Only fail the bar if it actually rendered (downloads were in flight);
		-- a resolution error (e.g. --locked pin check) never drew anything.
		if bar and ctx.downloads > 0 then bar:fail() end
		error(err)
	end
	download.finish()

	-- Finalize the download bar once downloads are done. When nothing was
	-- downloaded the bar never rendered anything, so it is finalized after the
	-- build pass below — where it either reports the builds or is discarded
	-- silently (the caller prints its own summary).
	if bar and ctx.downloads > 0 then bar:done() end

	-- Gets which features are enabled (+ OS specific features)
	local enabledOptional = resolveEnabledOptional(package, features)

	local buildOk, buildErr = pcall(function()
		-- Build in reverse discovery order: children (a rock's deps, including
		-- build backends like luarocks-build-rust-mlua) are discovered after
		-- their parent, so a reverse iteration builds every dependency before
		-- the rock that requires it. Rockspec builtin native compiles spawn
		-- concurrently (asyncBuild mode): gcc children are polled and their
		-- finalizers run once all of them finish, so independent rocks compile
		-- in parallel while ordering constraints are still respected.
		local order = ctx.order or {}

		local asyncBuild = require("lde-core.util.async-build")
		---@type { alias: string, finalize: fun(): boolean?, string? }[]
		local pending = {}
		---@type table<string, boolean>
		local pendingAlias = {}
		asyncBuild.begin()

		--- Wait for all spawned native compiles and run their finalizers.
		---@param forAlias string? # only drains when that alias has a pending build
		local function drain(forAlias)
			if forAlias and not pendingAlias[forAlias] then return end
			for _, job in ipairs(pending) do
				local ok, err = job.finalize()
				if not ok then
					error("Build failed for '" .. job.alias .. "': " .. tostring(err))
				end
				ctx.builds = ctx.builds + 1
			end
			pending = {}
			pendingAlias = {}
		end

		for i = #order, 1, -1 do
			local node = order[i]
			local alias = node.alias
			local entry = ctx.stack[alias]
			if not entry then goto continue end
			local depInfo = dependencies[alias]

			-- Optional, skip..
			if depInfo and depInfo.optional and not enabledOptional[alias] then
				goto continue
			end

			local dest = path.join(modulesDir, alias)

			-- Git/registry deps are symlinked (or built) into target/, and the
			-- symlink target encodes the resolved commit. This loop only runs when
			-- the lockfile changed (the fast path returns earlier), so a stale link
			-- from a previous commit must be dropped before the build re-creates it.
			if entry.lock.git and fs.islink(dest) then
				fs.delete(dest)
			end

			-- Has a build script, needs to run.
			if not fs.islink(dest) then
				-- A dependent whose build reads dependency outputs (make/cmake/
				-- command backends, or builtin rocks linking against a native
				-- dep's .so) must wait for those deps' pending compiles first.
				-- Pure-Lua builtin installs only copy their own sources, so they
				-- build without draining, keeping independent compiles overlapped.
				-- Non-rockspec packages (git/path with build scripts) default to
				-- draining to preserve the historical ordering guarantee.
				if entry.pkg.buildNeedsDeps ~= false then
					for depAlias in pairs(node.deps or {}) do
						drain(depAlias)
					end
				end
				local built, deferred = entry.pkg:build(dest)
				if deferred then
					pending[#pending + 1] = { alias = alias, finalize = deferred }
					pendingAlias[alias] = true
				elseif built then
					ctx.builds = ctx.builds + 1
				end
			end

			::continue::
		end

		drain()
		asyncBuild.finish()
	end)

	if not buildOk then
		error(buildErr)
	end

	local checked = 0
	for _ in pairs(ctx.stack) do checked = checked + 1 end

	-- With nothing downloaded or built the bar never rendered anything, so it
	-- is discarded silently for summary callers (they print the "No changes"
	-- line themselves, so both paths render identically) and finalized with the
	-- old "2ms" line for default callers (run/test/compile).
	if bar and ctx.downloads == 0 then
		if ctx.builds > 0 then
			bar:done()
		elseif not opts.summary then
			bar:done()
		end
	end

	commitLockfile(package, ctx.stack, modulesDir)

	return {
		checked = checked,
		installs = installs,
		changed = ctx.downloads > 0 or ctx.builds > 0,
		cached = false,
	}
end

return installDependencies
