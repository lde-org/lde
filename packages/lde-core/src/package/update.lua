const fs = require("fs")
const json = require("json")
const semver = require("semver")
const luarocks = require("luarocks")

const global = require("lde-core.global")
const util = require("lde-core.util")

const git2 = require("util").lazy(function() return require("git2-sys") end)

--- The entry as lde.json declares it: getDependencies() overlays the lockfile pin, so its merged view can't tell a user-pinned commit from one resolution recorded.
---@param package lde.Package
---@param name string
---@return lde.Package.Config.Dependency?
local function declaredDependency(package, name)
	local config = package:readConfig()
	const depInfo = config.dependencies?.[name]
	if depInfo then return depInfo end
	return config.devDependencies?.[name]
end

--- A git URL in comparable form: the same repository spelled with/without
--- `.git`, or with `git://` instead of `https://`, is not a source change.
---@param url string?
---@return string?
local function gitUrlKey(url)
	return url and util.normalizeGitUrl(url)
end

--- Whether a lockfile entry already pins the source a registry version
--- resolves to. An entry without a git URL predates registry deps recording
--- one: its commit came from the portfile's top-level git, so the commit alone
--- decides (clearing it would only force a no-op re-resolve).
---@param isLocked lde.Lockfile.Dependency
---@param commit string?
---@param git string?
---@param branch string?
---@param archive string?
---@param sha256 string?
local function lockMatchesSource(isLocked, commit, git, branch, archive, sha256)
	local locked = isLocked --[[@as {
		commit: string?, git: string?, branch: string?, archive: string?, sha256: string?
	}]]
	if archive then
		return locked.archive == archive and locked.sha256 == sha256
	end
	if locked.commit ~= commit then return false end
	if sha256 and locked.sha256 ~= sha256 then return false end
	if locked.git and git and gitUrlKey(locked.git) ~= gitUrlKey(git) then return false end
	-- The branch is only a clone hint, so a one-sided value (a legacy entry
	-- without one) is not a source change.
	if locked.branch and branch and locked.branch ~= branch then return false end
	return true
end

--- Drops a dependency's lockfile entry when it pins a source the resolved
--- version no longer uses, so the next install re-resolves from the registry.
---@param package lde.Package
---@param name string
---@param commit string?
---@param git string?
---@param branch string?
---@param archive string?
---@param sha256 string?
---@return boolean cleared
local function clearStaleLock(package, name, commit, git, branch, archive, sha256)
	const lockfile = package:readLockfile()
	const isLocked = lockfile and lockfile:getDependency(name)
	if not (lockfile and isLocked)
		or lockMatchesSource(isLocked, commit, git, branch, archive, sha256) then
		return false
	end
	const deps = lockfile:getDependencies()
	-- Decoded tables carry a key store, so a plain nil assignment would encode
	-- as "name": null instead of removing the entry.
	json.removeField(deps, name)
	lockfile:save()
	return true
end

---@param package lde.Package
---@param name string
---@param depInfo lde.Package.Config.GitDependency
---@return boolean updated
---@return string message
local function updateGitDependency(package, name, depInfo)
	-- A commit spelled out in lde.json is a deliberate pin: update only moves deps that follow a ref, or the lockfile would silently install a commit the manifest doesn't declare.
	const declared = declaredDependency(package, name)
	if declared and declared.commit then
		return false, "pinned in lde.json (" .. declared.commit:sub(1, 7) .. ")"
	end

	const ref = depInfo.branch ? ("refs/heads/" .. depInfo.branch) : "HEAD"
	local latestCommit, err = git2().lsRemote(depInfo.git, ref)
	if not latestCommit then
		return false, "failed: " .. (err or "unknown error")
	end ---@cast latestCommit string

	if depInfo.commit and latestCommit == depInfo.commit then
		return false, "already up to date (" .. latestCommit:sub(1, 7) .. ")"
	end

	-- Git deps that follow a ref have nothing in lde.json to write (the ref is the manifest), so the commit is pinned in the lockfile instead.
	local lockfile = package:readLockfile()
	if lockfile then
		local isLocked = lockfile:getDependency(name)
		if isLocked and isLocked.commit then
			isLocked.commit = latestCommit
			lockfile:save()
		end
	end

	const msg = depInfo.commit
		and (depInfo.commit:sub(1, 7) .. " -> " .. latestCommit:sub(1, 7))
		or ("at " .. latestCommit:sub(1, 7))

	return true, msg
end

---@param package lde.Package
---@param name string
---@param depInfo lde.Package.Config.RegistryDependency
---@return boolean updated
---@return string message
local function updateRegistryDependency(package, name, depInfo)
	global.syncRegistry()

	const packageName = depInfo.name or name
	local portfile, err = global.lookupRegistryPackage(packageName)
	if not portfile then
		return false, "registry error: " .. err
	end

	local versions = portfile.versions or {}

	-- A range floats: the lockfile is what pins it, so dropping its entry lets the next install resolve the newest allowed version.
	if not semver.isExact(depInfo.version) then
		local revoked = {}
		for _, revokedVersion in ipairs(portfile.revoked or {}) do
			revoked[revokedVersion] = true
		end
		local available = {}
		for candidate, entry in pairs(versions) do
			if not revoked[candidate] then available[candidate] = entry end
		end
		const resolved = semver.maxSatisfying(available, depInfo.version)
		if not resolved then
			return false, "no version satisfies " .. depInfo.version
		end ---@cast resolved -nil

		-- Compare against the selected version's effective source: a per-version
		-- git/branch override means the commit alone no longer identifies it.
		local _, commit, git, branch, archive, sha256 =
			global.resolveRegistryVersion(portfile, resolved)
		if clearStaleLock(package, name, commit, git, branch, archive, sha256) then
			return true, depInfo.version .. " -> " .. resolved
		end
		return false, "already up to date (" .. resolved .. ")"
	end

	local best = depInfo.version
	local revoked = {}
	for _, revokedVersion in ipairs(portfile.revoked or {}) do
		revoked[revokedVersion] = true
	end
	for v in pairs(versions) do
		if not revoked[v] and semver.isCompatibleUpdate(best, v) then
			best = v
		end
	end

	if best == depInfo.version then
		return false, "already up to date (" .. depInfo.version .. ")"
	end

	local configPath = package:getConfigPath()
	local configRaw = fs.read(configPath)
	if not configRaw then
		return false, "failed to read config"
	end

	local config, derr = util.decodeJson(configRaw)
	if not config then return false, "failed to parse lde.json: " .. derr end
	if config.dependencies and config.dependencies[name] then
		config.dependencies[name].version = best
	elseif config.devDependencies and config.devDependencies[name] then
		config.devDependencies[name].version = best
	end

	fs.write(configPath, json.encode(config))

	-- A bump can move the package to a different repository or branch
	-- (per-version overrides), so drop a lock entry pinning the old source.
	-- The rewritten manifest already invalidates the lockfile, but the entry
	-- must not keep claiming the previous git URL.
	local _, commit, git, branch, archive, sha256 =
		global.resolveRegistryVersion(portfile, best)
	clearStaleLock(package, name, commit, git, branch, archive, sha256)

	return true, depInfo.version .. " -> " .. best
end

---@param package lde.Package
---@param name string
---@param depInfo lde.Package.Config.Dependency
---@return boolean updated
---@return string message
local function updateLuarocksDependency(package, name, depInfo)
	local manifest, err = util.getManifest()
	if not manifest then return false, "manifest error: " .. (err or "") end

	const rocksName = depInfo.name or depInfo.luarocks
	const latestUrl = luarocks.getRockspecUrl(manifest --[[@as luarocks.Manifest]], rocksName)
	if not latestUrl then return false, "not found in luarocks registry" end

	const latest = latestUrl:match(rocksName .. "%-([^/]+)%.rockspec$")
	const current = depInfo.version

	if not latest or latest == current then
		return false, "already up to date" .. (current and (" (" .. current .. ")") or "")
	end

	local configPath = package:getConfigPath()
	local configRaw = fs.read(configPath)
	if not configRaw then return false, "failed to read config" end

	local config, derr = util.decodeJson(configRaw)
	if not config then return false, "failed to parse lde.json: " .. derr end
	if config.dependencies and config.dependencies[name] then
		config.dependencies[name].version = latest
	elseif config.devDependencies and config.devDependencies[name] then
		config.devDependencies[name].version = latest
	end

	fs.write(configPath, json.encode(config))
	return true, (current or "?") .. " -> " .. latest
end

---@param package lde.Package
---@param dependencies table<string, lde.Package.Config.Dependency>?
---@return table<string, { updated: boolean, message: string }>
local function updateDependencies(package, dependencies)
	dependencies = dependencies or package:getDependencies()

	const results = {}
	for name, depInfo in pairs(dependencies or {}) do
		local updated, message
		if depInfo.luarocks then
			if package.isRockspec then
				-- Rockspec deps are pinned by the rockspec itself; there's no lde.json to write a version to.
				updated, message = false, "managed by rockspec"
			else
				updated, message = updateLuarocksDependency(package, name, depInfo)
			end
		elseif depInfo.version then ---@cast depInfo lde.Package.Config.RegistryDependency
			updated, message = updateRegistryDependency(package, name, depInfo)
		elseif depInfo.git then ---@cast depInfo lde.Package.Config.GitDependency
			updated, message = updateGitDependency(package, name, depInfo)
		else
			updated, message = false, "skipped (path dependency)"
		end

		results[name] = { updated = updated, message = message }
	end

	return results
end

return updateDependencies
