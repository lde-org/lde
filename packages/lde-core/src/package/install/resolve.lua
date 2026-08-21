--- Dependency resolution: turns a manifest's dependency entries into a
--- resolved, materialized graph of "nodes". This module owns the two-phase
--- walk (metadata first, content after), the per-kind node behavior
--- (path/git/archive/luarocks), lockfile pinning, and conflict detection.
--- The install pass in `lde-core.package.install` supplies the context
--- (download session, build scheduler, modules dir) and consumes the result
--- (ctx.stack, ctx.order) to build and commit the lockfile.

local fs = require("fs")
local path = require("path")
local rocked = require("rocked")
local download = require("lde-core.util.download")

local lde = require("lde-core")

--- Copies config-only flags (optional, features) from a config entry onto a
--- lock entry.
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
---@field isLocked boolean? # --isLocked: fail when a dep isn't pinned in the lockfile
---@field downloads integer # content artifacts actually downloaded (0 = nothing to fetch)
---@field builds integer # build scripts actually run (0 = nothing to compile)
---@field dependencies table<string, lde.Package.Config.Dependency>
---@field modulesDir string
---@field enabledOptional table<string, true>
---@field build { addNode: fun(node: lde.install.Node), finish: fun() }
---@field order lde.install.Node[]?

---@class lde.install.DeferredBuild
---@field poll fun(): boolean? # true once the spawned build finished, nil while still running
---@field finalize fun(): boolean?, string? # waits for the build, verifies it, and stamps; true on success

---@class lde.install.ContentPlan
---@field kind "src"|"git"|"archive"|"clone"
---@field url string?  # download source (nil for the git-clone fallback)
---@field file string? # local cache file to download into (nil for clone)
---@field dir string?  # extraction target (nil for clone / isCached git)

---@class lde.install.GitPlan
---@field dir string
---@field commit string
---@field tarballUrl string?
---@field archiveFile string?
---@field url string? # resolved source URL (set when the config entry doesn't carry it: luarocks fallbacks, registry deps)
---@field clone { repoName: string, repoUrl: string, commit: string, branch: string? }?

---@class lde.install.Node
---@field alias string # key in the parent's dependencies table
---@field depInfo lde.Package.Config.Dependency
---@field kind "path"|"git"|"archive"|"luarocks"
---@field sourceKey string # identity used for conflict detection
---@field dir string? # path deps: resolved directory
---@field name string? # luarocks: package name (alias may differ)
---@field repoName string? # git/registry: package name to find inside the repo
---@field hasMetadata boolean? # luarocks: fetch the published rockspec for deps
---@field rockspecUrl string?
---@field rockspecFile string?
---@field version string?
---@field srcUrl string? # preferred content artifact (.src.rock)
---@field spec rocked.raw.Output?
---@field isExpandAfter boolean? # deps only knowable after content downloads
---@field gitPlan lde.install.GitPlan?
---@field deps table<string, lde.Package.Config.Dependency>?
---@field pkg lde.Package?
---@field expandDir string? # relativeTo base for the node's children
---@field isMaterialized boolean? # content already extracted/cloned this run
---@field _content lde.install.ContentPlan?
---@field _fallbackGit lde.install.GitPlan?

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

--- Normalized git identity for conflict comparison: equivalent spellings of
--- the same repo (trailing .git, git:// vs https://) must produce the same
--- key, or a git dep spelled one way would false-conflict with the same repo
--- spelled another. Local paths (no scheme) are left untouched.
---@param url string
---@return string
local function gitSourceKey(url)
	if url:match("://") then
		return "git:" .. lde.util.normalizeGitUrl(url)
	end
	return "git:" .. url
end

--- Approximate source key for a not-yet-materialized dependency, used to
--- detect conflicting sources when the same alias is requested from
--- different places.
---@param alias string
---@param depInfo lde.Package.Config.Dependency
---@param relativeTo string
---@return string
local function depSourceKey(alias, depInfo, relativeTo)
	depInfo = depInfo or {}
	if depInfo.path then
		return "path:" .. path.resolve(relativeTo, path.normalize(depInfo.path))
	elseif depInfo.git then
		-- The commit is a deterministic resolution detail (lsRemote HEAD or
		-- lockfile pin), so the source identity is the URL alone.
		return gitSourceKey(depInfo.git)
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
		-- Registry deps resolve to a git repo, so their identity is the
		-- resolved repo URL; fall back to the version form when the portfile
		-- can't be read (e.g. the registry hasn't been synced yet this run).
		local packageName = depInfo.name or alias
		local portfile = lde.global.lookupRegistryPackage(packageName)
		if portfile and portfile.git then
			return gitSourceKey(portfile.git)
		end
		return "registry:" .. packageName .. "@" .. (depInfo.version or "")
	end
	return "unknown"
end

--- Applies the root lockfile pin to a dependency entry, if present.
---@param ctx lde.install.Context
---@param alias string
---@param depInfo lde.Package.Config.Dependency
---@return lde.Package.Config.Dependency
local function applyLock(ctx, alias, depInfo)
	if ctx.rootLockfile then
		local isLocked = ctx.rootLockfile:getDependency(alias)
		if isLocked then
			isLocked = withConfigFlags(isLocked, depInfo)
			-- Lock entries written before registry deps recorded their git URL
			-- only carry a commit, so makeNode can't classify them. Fall back
			-- to the manifest's source fields (keeping any commit pin).
			local entry = isLocked ---@type any
			if not (entry.path or entry.git or entry.archive or entry.luarocks or entry.version) then
				local merged = {}
				for k, v in pairs(depInfo) do merged[k] = v end
				if isLocked.commit then merged.commit = isLocked.commit end
				return withConfigFlags(merged, depInfo) --[[@as lde.Package.Config.Dependency]]
			end
			return isLocked --[[@as lde.Package.Config.Dependency]]
		end
	end
	-- --locked installs: the lockfile must already pin every non-path
	-- dependency. Failing loudly instead of resolving a fresh commit/version
	-- is what keeps `lde sync --locked` reproducible and offline.
	if ctx.isLocked and not depInfo.path then
		lde.error.raise("Lockfile is out of date: '" .. alias .. "' is not pinned. Run `lde sync` to update it.")
	end
	return depInfo
end

--- Resolve a luarocks dependency to its version + metadata/content URLs.
---@param alias string
---@param depInfo lde.Package.Config.LuarocksDependency
---@return lde.install.Node
local function makeLuarocksNode(alias, depInfo)
	local name = depInfo.name or depInfo.luarocks -- the luarocks package name (alias may differ)
	local version, rockspecUrl, srcUrl, err = lde.util.resolveLuarocksBest(name, depInfo.version)
	if not version then
		lde.error.raise("Failed to resolve luarocks dep '" .. alias .. "': " .. (err or ""))
	end

	return {
		alias = alias,
		depInfo = depInfo,
		kind = "luarocks",
		name = name,
		version = version,
		sourceKey = "luarocks:" .. name .. "@" .. version,
		hasMetadata = rockspecUrl ~= nil,
		rockspecUrl = rockspecUrl,
		rockspecFile = rockspecUrl and lde.util.rockspecCacheFile(rockspecUrl) or nil,
		srcUrl = srcUrl, -- preferred content artifact; nil when no src rock exists
		isExpandAfter = not rockspecUrl, -- without a rockspec the deps come from the content
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
			sourceKey = gitSourceKey(depInfo.git),
			repoName = alias,
			gitPlan = gitPlan,
			isExpandAfter = true, -- monorepo: lde.json location unknown until extracted
		}
	elseif depInfo.archive then
		return {
			alias = alias,
			depInfo = depInfo,
			kind = "archive",
			sourceKey = "archive:" .. depInfo.archive,
			isExpandAfter = true, -- deps only known from the extracted content
		}
	elseif depInfo.luarocks then
		return makeLuarocksNode(alias, depInfo --[[@as lde.Package.Config.LuarocksDependency]])
	elseif depInfo.version then
		-- Registry packages are git repos (same resolution as a git dep).
		local packageName = depInfo.name or alias
		lde.global.syncRegistry()
		local portfile, err = lde.global.lookupRegistryPackage(packageName)
		if not portfile then
			lde.error.raise("Registry lookup failed for '" .. alias .. "': " .. err)
		end ---@cast portfile -nil
		local _, commit = lde.global.resolveRegistryVersion(portfile, depInfo.version)
		local gitPlan = lde.global.planGitRepo(packageName, portfile.git, portfile.branch, commit)
		-- The config entry only carries the version; the repo URL lives in the
		-- portfile. Record it on the plan so the lockfile entry can pin the git
		-- source (without it, a later install can't classify the dep).
		gitPlan.url = portfile.git
		return {
			alias = alias,
			depInfo = depInfo,
			kind = "git",
			-- Registry deps resolve to a git repo; their identity is the
			-- resolved repo URL (matching depSourceKey), so a second registry
			-- request — or a direct git request for the same repo — doesn't
			-- false-conflict.
			sourceKey = gitSourceKey(portfile.git),
			repoName = packageName,
			gitPlan = gitPlan,
			isExpandAfter = true,
		}
	else
		lde.error.raise("Unsupported dependency type for: " .. alias)
		error("unreachable", 0)
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
	node.isMaterialized = true
end

--- Open the node's package (requires content materialized).
---@param node lde.install.Node
---@return lde.Package
local function open(node)
	if node.pkg then return node.pkg end
	h(node).open(node)
	return node.pkg --[[@as lde.Package]]
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

--- Open a node's package, emit its lock entry, and record the stack entry
--- (raising on a source conflict for an alias already registered). Idempotent
--- for already-registered aliases; the conflict check always runs.
---@param node lde.install.Node
---@param ctx lde.install.Context
local function registerNode(node, ctx)
	local pkg = open(node)
	local lockEntry = lock(node)
	lockEntry.name = node.depInfo.name
	local existing = ctx.stack[node.alias]
	if existing then
		local existingKey = sourceKey(existing.lock, existing.pkg)
		local newKey = sourceKey(lockEntry, pkg)
		if existingKey ~= newKey then
			lde.error.raise("Conflicting sources for dependency '" .. node.alias .. "':\n  " .. existingKey .. "\n  " .. newKey)
		end
	else
		ctx.stack[node.alias] = { pkg = pkg, lock = withConfigFlags(lockEntry, node.depInfo) }
	end
end

--- Add a batch of deps to the graph, returning the newly created nodes. An
--- alias already in the graph is verified against the new request's source
--- instead of being re-created.
---@param deps table<string, lde.Package.Config.Dependency>
---@param relativeTo string
---@param ctx lde.install.Context
---@param graph table<string, lde.install.Node>
---@param order lde.install.Node[]
---@return lde.install.Node[]
local function addDeps(deps, relativeTo, ctx, graph, order)
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
				lde.error.raise("Conflicting sources for dependency '" .. alias .. "':\n  " .. existingKey .. "\n  " .. newKey)
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
			lde.error.raise("Failed to load local dependency package for: " .. n.alias .. "\nError: " .. err)
		end ---@cast pkg -nil
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
			local clone = n.gitPlan --[[@as lde.install.GitPlan]].clone --[[@as { repoName: string, repoUrl: string, commit: string, branch: string? }]]
			local ok, err = lde.global.cloneDir(clone.repoName, clone.repoUrl, clone.commit, clone.branch)
			if not ok then lde.error.raise("Failed to clone git repository: " .. (err or "unknown error")) end
			return
		end
		local res = download.result(c.file --[[@as string]])
		if res and not res.ok then lde.error.raise("Failed to download " .. c.url .. ": " .. (res.err or "")) end
		local ok, err = lde.global.extractGitTarball(c.file --[[@as string]], c.dir --[[@as string]])
		if not ok then lde.error.raise("Failed to extract " .. n.repoName .. ": " .. (err or "")) end
	end,
	---@param n lde.install.Node
	open = function(n)
		local gitPlan = n.gitPlan --[[@as lde.install.GitPlan]]
		local pkg, err = lde.util.findNamedPackage(gitPlan.dir, n.repoName, n.depInfo.rockspec)
		if not pkg then lde.error.raise(err or "No package found in git repository") end ---@cast pkg -nil
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
		-- Registry deps have no git field in their config entry; makeNode
		-- records the resolved repo URL on the plan (gitPlan.url) so it still
		-- gets pinned.
		return {
			git = gitPlan.url or n.depInfo.git,
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
		if res and not res.ok then lde.error.raise("Failed to download archive '" .. c.url .. "': " .. (res.err or "")) end
		local ok, err = lde.global.extractArchive(c.url --[[@as string]], c.file --[[@as string]], c.dir --[[@as string]])
		if not ok then lde.error.raise("Failed to extract archive '" .. c.url .. "': " .. (err or "")) end
	end,
	---@param n lde.install.Node
	open = function(n)
		local c = content(n) --[[@as lde.install.ContentPlan]]
		-- .src.rock archives contain a rockspec + the source tree; the source
		-- is either a subdir next to the rockspec or the nested archive.
		local pkgDir, rockspecPath = c.dir, n.depInfo.rockspec
		if n.depInfo.archive:match("%.src%.rock$") and not n.depInfo.rockspec then
			local srcDir, srcRockspec, merr = lde.util.materializeSrcRock(c.dir --[[@as string]])
			if not srcDir then
				lde.error.raise("Failed to load archive dependency '" .. n.alias .. "': " .. (merr or "unknown error"))
			end
			pkgDir, rockspecPath = srcDir, srcRockspec
		end
		local pkg, err = lde.Package.open(pkgDir, rockspecPath)
		if not pkg then lde.error.raise("Failed to load archive dependency '" .. n.alias .. "': " .. (err or "")) end ---@cast pkg -nil
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
			lde.error.raise("No source artifact for '" .. n.alias .. "'")
		end ---@cast source { url: string, branch: string?, tag: string? }
		local sourceUrl = source.url
		-- LuaRocks treats any of these as a git source: git://, git+https://,
		-- or a plain URL ending in .git; anything else is a plain archive.
		if sourceUrl:match("^git") or sourceUrl:match("%.git$") then
			sourceUrl = lde.util.normalizeGitUrl(sourceUrl)
			local fallback = lde.global.planGitRepo(n.name --[[@as string]], sourceUrl, source.branch or source.tag, nil)
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
			local clone = fallback.clone --[[@as { repoName: string, repoUrl: string, commit: string, branch: string? }]]
			local ok, err = lde.global.cloneDir(clone.repoName, clone.repoUrl, clone.commit, clone.branch)
			if not ok then lde.error.raise("Failed to clone git repository: " .. (err or "unknown error")) end
			return
		end
		local res = download.result(c.file --[[@as string]])
		if res and not res.ok then lde.error.raise("Failed to download " .. c.url .. ": " .. (res.err or "")) end
		local ok, err = lde.global.extractArchive(c.url --[[@as string]], c.file --[[@as string]], c.dir --[[@as string]])
		if not ok then lde.error.raise("Failed to extract '" .. (c.url or c.dir) .. "': " .. (err or "")) end
	end,
	---@param n lde.install.Node
	consume = function(n)
		if n.rockspecFile and fs.exists(n.rockspecFile) then
			local content = fs.read(n.rockspecFile) --[[@as string]]
			local ok, spec = rocked.parse(content)
			if not ok then
				lde.error.raise("Failed to parse rockspec '" .. tostring(n.rockspecUrl) .. "': " .. tostring(spec))
			end ---@cast spec rocked.raw.Output
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
			lde.error.raise("Missing rockspec for '" .. n.alias .. "': " .. tostring(n.rockspecUrl))
		end
	end,
	---@param n lde.install.Node
	open = function(n)
		local c = content(n)
		local pkg, err
		if c and c.kind == "src" then
			pkg, err = lde.util.openSrcRock(c.dir --[[@as string]], c.url --[[@as string]])
		else
			-- Rockspec-backed, or a git fallback whose repo dir was already
			-- cached (content() returns nil in that case).
			local pkgDir = c and c.dir or (n._fallbackGit and n._fallbackGit.dir or n.dir)
			pkg, err = lde.Package.openRockspec(pkgDir, n.rockspecUrl)
		end
		if not pkg then lde.error.raise("Failed to load '" .. n.name .. "': " .. (err or "")) end ---@cast pkg -nil
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

--- Resolves the whole dependency graph onto `ctx.stack` and `ctx.order`.
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
local function resolveDependencies(dependencies, ctx)
	---@type table<string, lde.install.Node>
	local graph = {} -- alias -> node
	---@type lde.install.Node[]
	local order = {} -- nodes in discovery order

	-- ── Phase 1: graph walk (metadata-only) ────────────────────────────────
	---@type lde.install.Node[]
	local frontier = addDeps(dependencies, ctx.relativeTo, ctx, graph, order)

	while #frontier > 0 do
		---@type lde.install.Node[]
		local nextFrontier = {}
		---@type lde.install.Node[]
		local metaBatch = {}
		---@type lde.install.Node[]
		local contentBatch = {}

		for _, node in ipairs(frontier) do
			if node.hasMetadata then
				-- Fetch the published rockspec (tiny) to discover deps.
				if not fs.exists(node.rockspecFile --[[@as string]]) then
					download.prefetch(node.rockspecUrl --[[@as string]], node.rockspecFile --[[@as string]])
				end
				metaBatch[#metaBatch + 1] = node
			elseif not node.isExpandAfter and not content(node) then
				-- path deps: nothing to download, consume and expand immediately.
				consume(node)
				for _, child in ipairs(addDeps(node.deps or {}, node.expandDir or ctx.relativeTo, ctx, graph, order)) do
					nextFrontier[#nextFrontier + 1] = child
				end
			end

			if node.isExpandAfter then
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
					for _, child in ipairs(addDeps(node.deps or {}, node.expandDir or ctx.relativeTo, ctx, graph, order)) do
						nextFrontier[#nextFrontier + 1] = child
					end
				end
			end
		end

		download.drain()

		for _, node in ipairs(metaBatch) do
			consume(node)
			for _, child in ipairs(addDeps(node.deps or {}, node.expandDir or ctx.relativeTo, ctx, graph, order)) do
				nextFrontier[#nextFrontier + 1] = child
			end
		end

		for _, node in ipairs(contentBatch) do
			materialize(node)
			consume(node)
			for _, child in ipairs(addDeps(node.deps or {}, node.expandDir or ctx.relativeTo, ctx, graph, order)) do
				nextFrontier[#nextFrontier + 1] = child
			end
		end

		frontier = nextFrontier
	end

	-- ── Phase 2: download all remaining content in one parallel batch ──────
	---@type lde.install.Node[]
	local contentNodes = {}
	---@type table<string, lde.install.Node>
	local contentByFile = {}
	for _, node in ipairs(order) do
		local c = content(node)
		-- Skip nodes whose content the walk already materialized (git clones
		-- have no cache dir to guard on, so without this they'd clone twice).
		if not node.isMaterialized and ((c and c.dir and not fs.exists(c.dir)) or (c and c.kind == "clone")) then
			if c.kind ~= "clone" then
				download.prefetch(c.url --[[@as string]], c.file --[[@as string]])
				contentByFile[c.file --[[@as string]]] = node
			end
			ctx.downloads = ctx.downloads + 1
			contentNodes[#contentNodes + 1] = node
		end
	end

	-- Pipeline: as each download lands, materialize + open the node and queue
	-- its build, so independent compiles overlap the remaining downloads.
	download.onTransfer(function(destPath)
		local node = contentByFile[destPath]
		if not node then return end
		materialize(node)
		ctx.build.addNode(node)
	end)
	download.drain()

	-- Materialize anything the pipeline didn't (git clones have no transfer).
	for _, node in ipairs(contentNodes) do
		if not node.isMaterialized then materialize(node) end
	end

	-- Queue the remaining nodes (cached/path deps never downloaded) for build.
	for _, node in ipairs(order) do
		ctx.build.addNode(node)
	end

	-- ── Phase 3: open every package and record the stack ───────────────────
	-- Idempotent for nodes the pipeline already registered; the conflict
	-- check in registerNode still runs for every node.
	for _, node in ipairs(order) do
		registerNode(node, ctx)
	end

	-- Discovery order is a topological order (parents expand before their
	-- children), so the build pass can depend on it: build backends like
	-- luarocks-build-rust-mlua must land in target/ before the rock that
	-- requires them builds.
	ctx.order = order
end

return {
	resolveDependencies = resolveDependencies,
	registerNode = registerNode,
}
