local fs = require("fs")
local path = require("path")
local util = require("util")
local ansi = require("ansi")

local lde = require("lde-core")

-- Dependency resolution (the graph walk, node kinds, conflict detection) and
-- the install build pass. Resolution drives the scheduler via ctx.build.
local resolve = require("lde-core.package.install.resolve")

-- buildPackage plus the isStale stamp check the install fast path consults.
local build = require("lde-core.package.build")

-- Build timings collection (no-op while inactive; no dependency on lde-core).
local timings = require("lde-core.util.timings")

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

--- Hash of the lockfile, runtime version, manifest, and compile target. The
--- .installed marker only matches when all four are unchanged, so a --target
--- switch forces a reinstall that rebuilds native deps for the new target.
---@param content string
---@param manifest string
---@return string
local function installedHash(content, manifest)
	return util.hash(content .. "\n" .. tostring(lde.global.currentVersion)
		.. "\n" .. manifest .. "\n" .. lde.global.getTargetKey())
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
	-- Pin the manifest hash alongside the entries: installs only trust the pins
	-- while lde.json's dependency declarations still match (Lockfile:isStale).
	lockfile:setManifestHash(lde.Lockfile.manifestHash(pkg:readConfig()))
	lockfile:save()

	local content = assert(fs.read(pkg:getLockfilePath()), "Failed to read " .. pkg:getLockfilePath())
	-- Hash the lockfile together with the lde runtime version (binary upgrades
	-- invalidate the cache), the manifest (a hand-edited lde.json must too),
	-- and the compile target (a --target switch must rebuild native deps), so
	-- the fast path only skips installs that are genuinely up to date.
	local manifest = fs.read(pkg:getConfigPath()) or ""
	fs.write(path.join(modulesDir, ".installed"), installedHash(content, manifest))
end

--- Build scheduler for the install build pass.
---
--- Nodes become buildable the moment their content is materialized *and* every
--- dependency whose build they can read has finished, so independent rocks
--- (and their gcc compiles) start building while the download batch is still
--- draining — overlapping the build with the download tail. Ordering
--- constraints are preserved via `hasBuildDeps` (the same rule the old
--- sequential loop used).
---@param ctx lde.install.Context
---@return { addNode: fun(node: lde.install.Node), finish: fun() }
local function makeBuildScheduler(ctx)
	local asyncBuild = require("lde-core.util.async-build")

	-- Cross-platform sleep used while polling spawned build workers so the
	-- loop doesn't busy-wait between checks.
	local ffi = require("ffi")
	local sleep
	if jit.os == "Windows" then
		pcall(ffi.cdef, "void Sleep(unsigned long dwMilliseconds);")
		sleep = function(ms) ffi.C.Sleep(ms) end
	else
		pcall(ffi.cdef, "int usleep(unsigned int usec);")
		sleep = function(ms) ffi.C.usleep(ms * 1000) end
	end

	---@type { alias: string, build: lde.install.DeferredBuild, handle: timings.Handle? }[]
	local pending = {}
	---@type table<string, boolean>
	local done = {}      -- alias -> build finished or skipped
	---@type lde.install.Node[]
	local queue = {}     -- content-ready nodes waiting to build
	---@type table<string, boolean>
	local queued = {}    -- alias -> addNode already ran
	---@type table<string, boolean>
	local attempted = {} -- alias -> attemptBuild already ran
	---@type table<string, table<string, true>> # alias -> direct dependency aliases (build graph edges)
	local children = {}
	---@type table<string, boolean>
	local building = {}  -- alias -> a build is in flight (row shown on the progress region)

	-- Forward declarations: the functions below reference each other.
	local pumpQueue
	local attemptBuild

	--- How many of a dependency's transitive closure (itself included) are
	--- built so far, and its total size. Shown on that dependency's progress
	--- row as `built/total` — e.g. `curl-sys 3/8` means 3 of the 8 packages
	--- curl-sys pulls in are built.
	---@param alias string
	---@return integer built
	---@return integer total
	local function subtreeCount(alias)
		local seen = { [alias] = true }
		local frontier = { alias }
		local built, total = done[alias] and 1 or 0, 1
		while #frontier > 0 do
			local a = table.remove(frontier)
			for child in pairs(children[a] or {}) do
				if not seen[child] then
					seen[child] = true
					total += 1
					if done[child] then built += 1 end
					frontier[#frontier + 1] = child
				end
			end
		end
		return built, total
	end

	--- Push the completed/total counts onto the install progress region:
	--- the total bar (install-wide done/total) and each building row's own
	--- built/total count.
	local function updateProgress()
		if not ctx.progress then return end
		local doneCount, total = 0, 0
		for _ in pairs(done) do doneCount += 1 end
		for _ in pairs(ctx.stack) do total += 1 end
		ctx.progress:update(total > 0 and doneCount / total or nil, doneCount .. "/" .. total)
		for alias in pairs(building) do
			local built, sub = subtreeCount(alias)
			ctx.progress:setDepCount(alias, built, sub)
		end
	end

	--- Drop a finished dependency from the progress region (its row clears)
	--- and push the total bar forward.
	---@param alias string
	local function finishAlias(alias)
		building[alias] = nil
		if ctx.progress then
			ctx.progress:finish(alias)
			updateProgress()
		end
	end

	--- Whether a node's build may run now: its package is open, and every dep
	--- it can read outputs from has finished building.
	---@param node lde.install.Node
	---@return boolean
	local function ready(node)
		if not ctx.stack[node.alias] then return false end
		local entry = ctx.stack[node.alias]
		if entry.pkg.hasBuildDeps ~= false then
			for depAlias in pairs(node.deps or {}) do
				if not done[depAlias] then return false end
			end
		end
		return true
	end

	--- Run a deferred finalizer once its spawned compiles finished.
	---@param job { alias: string, build: lde.install.DeferredBuild, handle: timings.Handle? }
	local function finalizeJob(job)
		local ok, err = job.build.finalize()
		if not ok then
			lde.error.raise("Build failed for '" .. job.alias .. "': " .. tostring(err))
		end
		if job.handle then timings.finish(job.handle) end
		ctx.builds += 1
		done[job.alias] = true
		finishAlias(job.alias)
		pumpQueue()
	end

	--- Attempt to build one node (spawning gcc async when asyncBuild is active).
	---@param node lde.install.Node
	attemptBuild = function(node)
		local alias = node.alias
		if attempted[alias] then return end
		local entry = ctx.stack[alias]
		if not entry then return end

		-- Optional deps that aren't enabled for this platform: skip, but mark
		-- them done so dependents don't wait on them (clearing any
		-- download-time row the resolver spawned).
		local depInfo = ctx.dependencies[alias]
		if depInfo and depInfo.optional and not ctx.enabledOptional[alias] then
			attempted[alias] = true
			done[alias] = true
			if ctx.progress then ctx.progress:finish(alias) end
			return
		end

		if not ready(node) then return end
		attempted[alias] = true

		local dest = path.join(ctx.modulesDir, alias)

		-- Git/registry deps are symlinked (or built) into target/, and the
		-- symlink target encodes the resolved commit. Drop a stale link from a
		-- previous commit before the build re-creates it.
		if entry.lock.git and fs.islink(dest) then
			fs.delete(dest)
		end

		-- Already a symlink (path deps / no-build git deps): nothing to build.
		-- Clear any download-time row the resolver spawned for this dep.
		if fs.islink(dest) then
			done[alias] = true
			if ctx.progress then
				ctx.progress:finish(alias)
				updateProgress()
			end
			return
		end

		-- The progress region keeps (or spawns) a row for this dependency while
		-- its build runs (cleared again by finishAlias). Only deps that do real
		-- work build here; the marker is picked lazily from what is already
		-- known — no I/O beyond the one stat below.
		local pkg = entry.pkg
		local hasBuildLua = fs.exists(pkg:getBuildScriptPath())
		local isBuild = pkg.buildfn ~= nil or hasBuildLua
		if ctx.progress and isBuild then
			building[alias] = true
			local kind = hasBuildLua and "tools" or (pkg.isRockspec and "rock" or "wrench")
			ctx.progress:setCurrent(alias, kind)
		end

		-- The unit spans the real build: from pkg:build() to the deferred
		-- finalizer (spawned compiles draining) or the synchronous return.
		local buildHandle = timings.active() and timings.start("build " .. alias, "build") or nil
		local hasBuilt, deferred = pkg:build(dest)
		if deferred then
			pending[#pending + 1] = { alias = alias, build = deferred, handle = buildHandle }
		else
			if buildHandle then timings.finish(buildHandle) end
			done[alias] = true
			if hasBuilt then ctx.builds += 1 end
			-- finish is a no-op when the dep never spawned a row (no build
			-- script, or a cached build that returned early).
			building[alias] = nil
			if ctx.progress then
				ctx.progress:finish(alias)
				updateProgress()
			end
			pumpQueue()
		end
	end

	--- Try to build every queued node that is now ready.
	pumpQueue = function()
		local hasProgressed = true
		while hasProgressed do
			hasProgressed = false
			for _, node in ipairs(queue) do
				if not attempted[node.alias] and ready(node) then
					attemptBuild(node)
					hasProgressed = true
				end
			end
		end
	end
	local scheduler = {}

	--- Queue a node for building; opens its package and records its stack
	--- entry first (once per alias). Idempotent per alias.
	---@param node lde.install.Node
	function scheduler.addNode(node)
		local alias = node.alias
		if queued[alias] then return end
		queued[alias] = true
		queue[#queue + 1] = node
		-- Record the build-graph edge (used for per-dependency subtree counts).
		local set = children[alias] or {}
		for depAlias in pairs(node.deps or {}) do set[depAlias] = true end
		children[alias] = set
		if not ctx.stack[alias] then
			resolve.registerNode(node, ctx)
		end
		pumpQueue()
	end

	--- Wait for all spawned compiles, then build whatever is left. Finalize
	--- each job as soon as its children exit (rather than in spawn order) so
	--- progress bars report accurate elapsed times and dependents unblock
	--- promptly.
	function scheduler.finish()
		while #pending > 0 do
			local hasProgressed = false
			local i = 1
			while i <= #pending do
				local job = pending[i]
				if job.build.poll() ~= nil then
					table.remove(pending, i)
					finalizeJob(job)
					hasProgressed = true
					-- finalizeJob may pump the queue and append new jobs; keep
					-- this index to re-check the element that shifted into it.
				else
					i += 1
				end
			end
			if not hasProgressed then
				sleep(20)
				-- Refresh the progress region while spawned build workers run:
				-- per-row elapsed counters animate and each row's built/total
				-- count stays current as dependencies finish around it.
				if ctx.progress then updateProgress() end
			end
		end
		pumpQueue()
		asyncBuild.finish()
	end

	asyncBuild.begin()
	return scheduler
end

--- True when every requested dependency is actually materialized in the modules
--- dir. The .installed marker hash only proves the lockfile/manifest didn't
--- change; it can't see materialization wiped out of band — deleting ~/.lde/git
--- leaves the git-dep symlinks in target/ dangling, and a deleted target/<alias>
--- is simply missing. Detecting that here falls back to a full install which
--- re-downloads and re-materializes, instead of `lde run` failing at require time.
---
--- Also verified: path deps with a build.lua whose stamped output is stale
--- (a src file changed since the last build). The marker can't see that either,
--- and without the check a stale copy in target/ would be served forever.
--- Symlinked deps (no build script) and rockspec/Teal/moonscript deps are
--- always "fresh" here: symlinks track the source, and the others stamp on
--- their own rockspec content instead of raw sources.
---@param package lde.Package
---@param dependencies table<string, lde.Package.Config.Dependency>
---@param enabledOptional table<string, true>
---@param modulesDir string
---@return boolean
local function isInstallIntact(package, dependencies, enabledOptional, modulesDir)
	if not fs.isdir(modulesDir) then return false end

	for alias, depInfo in pairs(dependencies) do
		-- Optional deps disabled for this platform were never materialized.
		if depInfo.optional and not enabledOptional[alias] then
			goto continue
		end
		-- fs.exists follows symlinks, so a dangling git-dep link (its cache dir
		-- was wiped) reports missing here and forces a reinstall.
		if not fs.exists(path.join(modulesDir, alias)) then
			return false
		end
		-- Path deps with a build.lua materialize a copy under target/<alias>
		-- stamped with their input state. If the dep's source moved on, the copy
		-- must be rebuilt — the root marker can't tell.
		if depInfo.path then
			local depDir = path.resolve(package.dir, path.normalize(depInfo.path))
			if fs.exists(path.join(depDir, "build.lua")) then
				local ok, depPkg = pcall(lde.Package.open, depDir)
				local dest = path.join(modulesDir, alias)
				if not ok or not depPkg or build.isStale(depPkg, dest) then
					return false
				end
			end
		end
		::continue::
	end

	return true
end

---@param package lde.Package
---@param dependencies table<string, lde.Package.Config.Dependency>?
---@param relativeTo string?
---@param features lde.Package.Config.FeatureFlag[]?
---@param opts { summary: boolean?, isLocked: boolean?, rootExtract: fun()? }?
---@return { checked: integer, installs: integer, hasChanged: boolean, isCached: boolean }
local function installDependencies(package, dependencies, relativeTo, features, opts)
	local isRoot = dependencies == nil
	dependencies = dependencies or package:getDependencies()
	relativeTo = relativeTo or package.dir
	opts = opts or {}

	features = features or {}
	features[#features + 1] = platformLookup[jit.os]

	local modulesDir = package:getModulesDir()

	-- Gets which features are enabled (+ OS specific features); the install
	-- integrity check and the build scheduler both consult it.
	local enabledOptional = resolveEnabledOptional(package, features)

	-- Nothing to do (or already done): report the direct dep count so callers
	-- can still print a "No changes" summary line. cached = the install was a
	-- no-op because everything was already materialized.
	local function noopResult()
		local installs = 0
		for _ in pairs(dependencies) do installs += 1 end
		return { checked = installs, installs = installs, hasChanged = false, isCached = true }
	end

	-- Temporary: a .skip marker in target/ (written by minilde during the
	-- bootstrap) means the deps are already materialized — skip all install
	-- work so nothing gets re-downloaded or re-built.
	if isRoot and fs.exists(path.join(modulesDir, ".skip")) then return noopResult() end

	-- Fast path: if target/.installed hash matches the current lockfile, skip all work.
	-- Bypassed under --locked so it always re-verifies the manifest against the
	-- lockfile instead of trusting the marker.
	if isRoot and not opts.isLocked then
		local installedPath = path.join(modulesDir, ".installed")
		local lockfilePath = package:getLockfilePath()
		if fs.exists(lockfilePath) and fs.exists(installedPath) then
			local content = fs.read(lockfilePath)
			-- commitLockfile writes installedHash; the check must use the same
			-- input or it can never match.
			local manifest = fs.read(package:getConfigPath()) or ""
			if content and fs.read(installedPath) == installedHash(content, manifest) then
				-- The hash only proves the lockfile didn't change; materialization
				-- may still be gone (e.g. `rm -rf ~/.lde/git` dangling the git
				-- symlinks in target/). Verify the install is intact before trusting
				-- the marker so `lde run` re-installs instead of failing at require.
				if isInstallIntact(package, dependencies, enabledOptional, modulesDir) then
					return noopResult()
				end
			end
		end
	end

	-- The lockfile's pins are only trustworthy while lde.json's dependency
	-- declarations match what the lockfile was resolved from. A manifest edit
	-- (switching a git dep to a registry dep, adding/removing deps, ...) makes
	-- them stale: applying them would override the new declarations, or conflict
	-- with transitive requests for the same alias. Re-resolve everything from
	-- the manifest and rewrite the lockfile instead.
	local rootLockfile = package:readLockfile()
	local isLockfileStale = rootLockfile ~= nil and rootLockfile:isStale(package:readConfig())
	if opts.isLocked and isLockfileStale then
		lde.error.raise("Lockfile is out of date: lde.json dependencies changed since it was written. Run `lde sync` to update it.")
	end
	if isLockfileStale then rootLockfile = nil end

	local ctx = {
		relativeTo = relativeTo,
		stack = {},
		-- The lockfile pins every previously-resolved alias (runtime and dev),
		-- so dev-dependency installs resolve from it instead of lsRemote-ing.
		rootLockfile = rootLockfile,
		isLocked = opts.isLocked,
		downloads = 0,
		builds = 0,
		-- Build-scheduler inputs.
		dependencies = dependencies,
		modulesDir = modulesDir,
		enabledOptional = enabledOptional,
	}
	ctx.build = makeBuildScheduler(ctx)

	local installs = 0
	for _ in pairs(dependencies) do installs += 1 end

	-- Parallel download session: sources are prefetched in batches during the
	-- graph walk and materialized afterwards. Always cleaned up, even on error.
	--
	-- Compact mode shows one bun-style live line for the whole pass: the
	-- currently building dependency, a moving total progress bar, and the
	-- elapsed time for that dependency. Verbose mode keeps the old per-item
	-- progress bars.
	--
	-- A session may already be active when this install runs inside an
	-- overlapped `install rocks:` flow (the root package's own download started
	-- before resolution). In that case the session is shared and the caller
	-- ends it.
	local download = require("lde-core.util.download")
	local isSessionActive = download.active()
	local progress = (not lde.isVerbose and not lde.isQuiet and installs > 0)
		and ansi.installProgress("Downloading dependencies") or nil
	ctx.progress = progress
	if not isSessionActive then
		download.begin(progress and {
			progress = function(done, total)
				local ratio = total > 0 and (done / total) or nil
				progress:update(ratio, ansi.formatBytes(done) .. " / " .. ansi.formatBytes(total))
			end
		} or nil)
	end

	local resolveHandle = timings.active()
		and timings.start("resolve " .. package:getName(), "download") or nil
	local ok, err = pcall(resolve.resolveDependencies, dependencies, ctx)
	if not ok then
		download.abort()
		-- Clear the live progress line; the error boundary prints the message.
		if progress then progress:clear() end
		lde.error.raise(err)
	end
	if not isSessionActive then download.finish() end
	if resolveHandle then timings.finish(resolveHandle) end

	-- Overlapped `install rocks:` installs start the root package's .src.rock
	-- download before resolution; materialize it now that the content batch has
	-- drained, so the build pass and lockfile commit see a real package dir.
	if opts and opts.rootExtract then
		opts.rootExtract()
	end

	-- Finish the build pass: drain any spawned compiles and build whatever the
	-- pipeline didn't get to (cached/path deps that never downloaded).
	ctx.build.finish()

	if not fs.exists(modulesDir) then fs.mkdir(modulesDir) end

	-- Finalize the unified progress line: committed ✓ lines stay above, the
	-- live line is replaced by a summary (or cleared when the caller prints
	-- its own summary). Nothing was downloaded or built → clear silently so
	-- summary callers render their "No changes" line identically.
	local checked = 0
	for _ in pairs(ctx.stack) do checked += 1 end

	if progress then
		if ctx.downloads > 0 or ctx.builds > 0 then
			if opts.summary then
				progress:clear()
			else
				progress:done(string.format("%d packages installed", checked))
			end
		else
			progress:clear()
		end
	end

	commitLockfile(package, ctx.stack, modulesDir)

	return {
		checked = checked,
		installs = installs,
		hasChanged = ctx.downloads > 0 or ctx.builds > 0,
		isCached = false,
	}
end

return installDependencies
