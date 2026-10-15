const fs = require("fs")
const path = require("path")
const util = require("util")
const ansi = require("ansi")

const lde = require("lde-core")

-- Dependency resolution (the graph walk, node kinds, conflict detection).
-- Resolution drives the scheduler via ctx.build.
const resolve = require("lde-core.package.install.resolve")
const scheduler = require("lde-core.package.install.scheduler")
-- Feature flags: which are on for a package, and what they turn on for it.
-- (Named `featureFlags` because `features` is this module's parameter for the
-- flags the caller asked for.)
const featureFlags = require("lde-core.package.features")
-- buildPackage plus the isStale stamp check the install fast path consults.
local build = require("lde-core.package.build")

-- Build timings collection (no-op while inactive; no dependency on lde-core).
const timings = require("lde-core.util.timings")

--- Hash of the lockfile, runtime version, manifest, and compile target. The
--- .installed marker only matches when all four are unchanged, so a --target
--- switch forces a reinstall that rebuilds native deps for the new target.
---@param content string
---@param manifest string
local function installedHash(content, manifest)
	return util.hash(content .. "\n" .. tostring(lde.global.currentVersion)
		.. "\n" .. manifest .. "\n" .. lde.global.getTargetKey())
end

--- Saves the lockfile and writes the .installed hash marker.
---@param pkg lde.Package
---@param stack table<string, { pkg: lde.Package, lock: lde.Lockfile.Dependency }>
---@param modulesDir string
---@param isStale boolean? # true when lde.json changed since the old lockfile was written
local function commitLockfile(pkg, stack, modulesDir, isStale)
	-- Runtime and dev installs each commit their own slice, so merge with the existing
	-- lockfile instead of dropping the other slice's pins. A stale lockfile's pins come
	-- from declarations that no longer match lde.json: keeping them would let the next
	-- slice trust a version the new manifest never asked for. Commit only the fresh
	-- stack. Copy into a fresh table because json encodes a decoded table in its internal
	-- key order, which mutating the decoded table would corrupt.
	const lockEntries = {}
	if not isStale then
		const existing = pkg:readLockfile()
		if existing then
			for alias, entry in pairs(existing:getDependencies()) do
				lockEntries[alias] = entry
			end
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
	const isRoot = dependencies == nil
	dependencies = dependencies or package:getDependencies()
	relativeTo = relativeTo or package.dir
	opts = opts or {}

	features = features or {}

	local modulesDir = package:getModulesDir()

	-- The root's own optional deps: which of them the features it was asked for turn
	-- on, the platform's flag among them. The same question is asked again for every
	-- package the walk reaches, in the resolver, where the declaring package of each
	-- dependency is still known -- this one only answers for the root, and is what
	-- the integrity check below consults.
	local enabledOptional = resolve.enabledOptional(package, features)

	-- Likewise record the root's own flags, so its build script asks the same
	-- questions about itself that the resolver answers for each dependency.
	package:setFeatures(featureFlags.enabledFlags(featureFlags.of(package), features))

	-- Nothing to do (or already done): report the direct dep count so callers
	-- can still print a "No changes" summary line. cached = the install was a
	-- no-op because everything was already materialized.
	local function noopResult()
		local installs = 0
		for _ in pairs(dependencies or {}) do installs += 1 end
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
		const installedPath = path.join(modulesDir, ".installed")
		const lockfilePath = package:getLockfilePath()
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
				if isInstallIntact(package, dependencies or {}, enabledOptional, modulesDir) then
					return noopResult()
				end
			end
		end
	end

	-- A pin is only trustworthy while lde.json still declares what it was resolved
	-- from; a manifest edit (git dep to registry dep, deps added or removed) makes it
	-- stale, and applying it would override the new declaration. Re-resolve instead.
	local rootLockfile = package:readLockfile()
	const isLockfileStale = rootLockfile ~= nil and rootLockfile:isStale(package:readConfig())
	if opts.isLocked and isLockfileStale then
		lde.error.raise("Lockfile is out of date: lde.json dependencies changed since it was written. Run `lde sync` to update it.")
	end
	if isLockfileStale then rootLockfile = nil end

	const ctx = {
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
	ctx.build = scheduler.new(ctx --[[@as lde.install.Context]])

	local installs = 0
	for _ in pairs(dependencies or {}) do installs += 1 end

	-- Parallel download session: sources are prefetched in batches during the
	-- graph walk and materialized afterwards. Always cleaned up, even on error.
	--
	-- One live line for the whole pass (compact) or a bar per item (verbose).
	-- An `install rocks:` flow starts the session before resolution; a shared
	-- session is left for that caller to end.
	const download = require("lde-core.util.download")
	const isSessionActive = download.active()
	const progress = (not lde.isVerbose and not lde.isQuiet and installs > 0)
		? ansi.installProgress("Downloading dependencies") : nil
	ctx.progress = progress
	if not isSessionActive then
		-- User-level archive cache: downloaded content bytes are reusable
		-- across trees (they're immutable, URL-addressed bytes; the extracted
		-- dirs stay per-tree). Fresh trees seed from it instead of the network,
		-- mirroring how the URL cache and manifest are already user-level.
		download.begin(progress and {
			archiveCache = path.join(lde.global.getUserDir(), "archives"),
			progress = function(done, total)
				local ratio = total > 0 ? (done / total) : nil
				progress:update(ratio, ansi.formatBytes(done) .. " / " .. ansi.formatBytes(total))
			end
		} or {
			archiveCache = path.join(lde.global.getUserDir(), "archives"),
		})
	end

	const resolveHandle = timings.active()
		? timings.start("resolve " .. package:getName(), "download") : nil
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

	-- Report dependencies that failed to download/extract. The rest of the
	-- graph was still downloaded and built; each failed node's cache state was
	-- cleaned, so the next sync re-fetches it instead of deadlocking on a
	-- partial dir. The lockfile is left untouched so failed pins don't stick.
	if ctx.failures and #ctx.failures > 0 then
		local parts = {}
		for _, node in ipairs(ctx.failures or {}) do
			parts[#parts + 1] = "  - " .. node.alias .. ": " .. node.error
		end
		lde.error.raise("Failed to install " .. #ctx.failures .. " dependenc"
			.. (#ctx.failures == 1 ? "y" : "ies") .. ":\n" .. table.concat(parts, "\n"))
	end

	commitLockfile(package, ctx.stack, modulesDir, isLockfileStale)

	return {
		checked = checked,
		installs = installs,
		hasChanged = ctx.downloads > 0 or ctx.builds > 0,
		isCached = false,
	}
end

return installDependencies
