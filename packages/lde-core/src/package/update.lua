local fs = require("fs")
local json = require("json")
local semver = require("semver")
local luarocks = require("luarocks")

local global = require("lde-core.global")
local util = require("lde-core.util")

local git2 = require("util").lazy(function() return require("git2-sys") end)

--- Checks a git dependency for newer commits via ls-remote and pins any
--- newer commit in the lockfile.
---@param package lde.Package
---@param name string
---@param depInfo lde.Package.Config.GitDependency
---@return boolean updated
---@return string message
local function updateGitDependency(package, name, depInfo)
	local ref = depInfo.branch and ("refs/heads/" .. depInfo.branch) or "HEAD"
	local latestCommit, err = git2().lsRemote(depInfo.git, ref)
	if not latestCommit then
		return false, "failed: " .. (err or "unknown error")
	end

	if depInfo.commit and latestCommit == depInfo.commit then
		return false, "already up to date (" .. latestCommit:sub(1, 7) .. ")"
	end

	-- Pin the new commit in the lockfile so the next install uses it.
	-- (Registry/luarocks updates write to lde.json instead; git commits only
	-- live in the lockfile, which is what getDependencies() reports from.)
	local lockfile = package:readLockfile()
	local locked = lockfile and lockfile:getDependency(name)
	if locked and locked.commit then
		locked.commit = latestCommit
		lockfile:save()
	end

	local msg = depInfo.commit
		and (depInfo.commit:sub(1, 7) .. " -> " .. latestCommit:sub(1, 7))
		or ("at " .. latestCommit:sub(1, 7))

	return true, msg
end

--- Updates a registry dependency to the latest compatible version (same major).
--- Writes the new version back to lde.json if updated.
---@param package lde.Package
---@param name string
---@param depInfo lde.Package.Config.RegistryDependency
---@return boolean updated
---@return string message
local function updateRegistryDependency(package, name, depInfo)
	global.syncRegistry()

	local packageName = depInfo.name or name
	local portfile, err = global.lookupRegistryPackage(packageName)
	if not portfile then
		return false, "registry error: " .. err
	end

	-- Find the latest compatible version (same major, higher minor/patch)
	local best = depInfo.version
	for v in pairs(portfile.versions) do
		if semver.isCompatibleUpdate(best, v) then
			best = v
		end
	end

	if best == depInfo.version then
		return false, "already up to date (" .. depInfo.version .. ")"
	end

	-- Write the updated version back to lde.json
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

	return true, depInfo.version .. " -> " .. best
end

--- Updates a luarocks dependency to the latest version.
---@param package lde.Package
---@param name string
---@param depInfo lde.Package.Config.Dependency
---@return boolean updated
---@return string message
local function updateLuarocksDependency(package, name, depInfo)
	local manifest, err = util.getManifest()
	if not manifest then return false, "manifest error: " .. (err or "") end

	local latestUrl = luarocks.getRockspecUrl(manifest, depInfo.luarocks)
	if not latestUrl then return false, "not found in luarocks registry" end

	local latest = latestUrl:match(depInfo.luarocks .. "%-([^/]+)%.rockspec$")
	local current = depInfo.version

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

--- Updates all dependencies for a package.
---@param package lde.Package
---@param dependencies table<string, lde.Package.Config.Dependency>?
---@return table<string, { updated: boolean, message: string }>
local function updateDependencies(package, dependencies)
	dependencies = dependencies or package:getDependencies()

	local results = {}
	for name, depInfo in pairs(dependencies) do
		local updated, message
		if depInfo.version then ---@cast depInfo lde.Package.Config.RegistryDependency
			updated, message = updateRegistryDependency(package, name, depInfo)
		elseif depInfo.git then ---@cast depInfo lde.Package.Config.GitDependency
			updated, message = updateGitDependency(package, name, depInfo)
		elseif depInfo.luarocks then
			updated, message = updateLuarocksDependency(package, name, depInfo)
		else
			updated, message = false, "skipped (path dependency)"
		end

		results[name] = { updated = updated, message = message }
	end

	return results
end

return updateDependencies
