local fs = require("fs")
local json = require("json")
local git = require("git")
local semver = require("semver")
local luarocks = require("luarocks")

local global = require("lde-core.global")
local util = require("lde-core.util")

--- Updates a single git dependency by pulling latest changes.
--- Only applies to git dependencies without a pinned commit.
---@param name string
---@param depInfo lde.Config.GitDependency
---@return boolean updated
---@return string message
local function updateGitDependency(name, depInfo)
	if depInfo.commit then
		return false, "skipped (pinned to commit)"
	end

	local repoDir = global.getGitRepoDir(name, depInfo.branch, depInfo.commit)
	if not fs.exists(repoDir) then
		return false, "skipped (not installed)"
	end

	local ok, output = git.pull(repoDir)
	if not ok then
		return false, "failed: " .. (output or "unknown error")
	end

	return true, (string.gsub(output or "updated", "%s+$", ""))
end

--- Updates a registry dependency to the latest compatible version (same major).
--- Writes the new version back to lde.json if updated.
---@param package lde.Package
---@param name string
---@param depInfo lde.Config.RegistryDependency
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

	local config = json.decode(configRaw)
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
---@param depInfo lde.Config.Dependency
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

	local config = json.decode(configRaw)
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
---@param dependencies table<string, lde.Config.Dependency>?
---@return table<string, { updated: boolean, message: string }>
local function updateDependencies(package, dependencies)
	dependencies = dependencies or package:getDependencies()

	local results = {}
	for name, depInfo in pairs(dependencies) do
		local updated, message
		if depInfo.version then ---@cast depInfo lde.Config.RegistryDependency
			updated, message = updateRegistryDependency(package, name, depInfo)
		elseif depInfo.git then ---@cast depInfo lde.Config.GitDependency
			updated, message = updateGitDependency(name, depInfo)
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
