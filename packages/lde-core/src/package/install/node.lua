--- Dependency-node model: the node/plan type declarations, the node
--- constructors, and the source-identity helpers resolve.lua's walk uses to
--- detect conflicts and apply lockfile pins.

const path = require("path")

local features = require("lde-core.package.features")

local lde = require("lde-core")

--- onto a lock entry. `exclude` is the resolved file list the enabled features
--- drop from this package's bundle; it is derived from the dependency's own
--- manifest, so it has to be recorded here for the bundler to see it later --
--- a dependency materialized as a copy keeps no manifest next to its modules.
---@param lockEntry lde.Lockfile.Dependency
---@param depInfo lde.Package.Config.Dependency
---@param pkg lde.Package? # the dependency's package, when it is already open
local function withConfigFlags(lockEntry, depInfo, pkg)
	lockEntry.optional = depInfo.optional
	lockEntry.features = depInfo.features
	if pkg then
		lockEntry.exclude = features.excludes(features.of(pkg), depInfo.features)
	end
	return lockEntry
end

--- Which of a package's optional deps are wanted: those named by a feature that is
--- on. The platform's flag is always on, and the rest are the ones the packages
--- depending on it asked for, which is the `features` list on a dependency entry.
---
--- A dependency entry's features belong to the package declaring it, not to the
--- package itself: winit's manifest says which of its optional deps `windows` and
--- `linux` turn on, and hood -- which depends on winit -- is the one that names
--- those flags. Nothing has to name the platform's own flag.
---@param pkg lde.Package
---@param requested lde.Package.Config.FeatureFlag[]? # as the dependency entries declared them
local function enabledOptional(pkg, requested)
	return features.enabledDependencies(features.of(pkg), requested)
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
---@field progress ansi.InstallProgress? # unified install progress line (compact mode)
---@field order lde.install.Node[]?
---@field failures lde.install.Node[]? # nodes whose download/extract failed

---@class lde.install.DeferredBuild
---@field poll fun(): boolean? # true once the spawned build finished, nil while still running
---@field finalize fun(): boolean?, string? # waits for the build, verifies it, and stamps; true on success
---@field lock lde.install.Lock? # build lock held until finalize (heartbeat target)

---@class lde.install.ContentPlan
---@field kind "src"|"git"|"archive"|"clone"
---@field url string?  # download source (nil for the git-clone fallback)
---@field file string? # local cache file to download into (nil for clone)
---@field dir string?  # extraction target (nil for clone / isCached git)
---@field srcDir string? # dir inside `dir` holding the source (source.dir, or the single root)

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
---@field wanted boolean? # false when every package that depends on it leaves it optional and off
---@field pkg lde.Package?
---@field expandDir string? # relativeTo base for the node's children
---@field isMaterialized boolean? # content already extracted/cloned this run
---@field error string? # materialization failed (download/extract); node is skipped
---@field _content lde.install.ContentPlan?
---@field _fallbackGit lde.install.GitPlan?

--- Returns a string key that uniquely identifies a dependency's source.
---@param entry lde.Lockfile.Dependency
---@param pkg lde.Package
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
		const constraint = depInfo.version or ""
		const v = lde.util.resolveLuarocksBest(name, constraint)
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
local function applyLock(ctx, alias, depInfo)
	if ctx.rootLockfile then
		local isLocked = ctx.rootLockfile:getDependency(alias)
		-- A commit spelled out in lde.json is the user's explicit pin, so a
		-- lockfile entry recording a different one must not win: the manifest
		-- stays the source of truth (a stale lock only comes from a lockfile
		-- written by an older lde, or hand-edited) and this install re-pins it.
		if isLocked and depInfo.commit and isLocked.commit ~= depInfo.commit then
			isLocked = nil
		end
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
		rockspecFile = rockspecUrl ? lde.util.rockspecCacheFile(rockspecUrl) : nil,
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

---@class lde.install.Handler
---@field content fun(node: lde.install.Node): lde.install.ContentPlan?
---@field materialize fun(node: lde.install.Node, content: lde.install.ContentPlan)
---@field consume fun(node: lde.install.Node)
---@field open fun(node: lde.install.Node)
---@field lock fun(node: lde.install.Node): lde.Lockfile.Dependency

return {
	withConfigFlags = withConfigFlags,
	enabledOptional = enabledOptional,
	sourceKey = sourceKey,
	gitSourceKey = gitSourceKey,
	depSourceKey = depSourceKey,
	applyLock = applyLock,
	makeLuarocksNode = makeLuarocksNode,
	makeNode = makeNode,
}
