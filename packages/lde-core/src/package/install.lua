local fs = require("fs")
local path = require("path")
local git = require("git")
local util = require("util")

local lde = require("lde-core")

---@param alias string
---@param depInfo lde.Config.Dependency
---@param relativeTo string
---@return lde.Package, lde.Lockfile.Dependency
local function dependencyToPackage(alias, depInfo, relativeTo)
	local packageName = depInfo.name or alias

	if depInfo.git then
		local repoDir = lde.global.getOrInitGitRepo(packageName, depInfo.git, depInfo.branch, depInfo.commit)

		local resolvedCommit = depInfo.commit
		if not resolvedCommit then
			local ok, output = git.getCommitHash(repoDir)
			resolvedCommit = (ok and output) and string.gsub(output, "%s+$", "") or nil
			if not resolvedCommit then
				error("Failed to resolve HEAD commit for git dependency")
			end
		end

		---@type lde.Lockfile.GitDependency
		local lockEntry = {
			git = depInfo.git,
			commit = resolvedCommit,
			branch = depInfo.branch,
			name = depInfo.name,
			rockspec =
				depInfo.rockspec
		}

		local pkg = lde.Package.open(repoDir, depInfo.rockspec)
		if pkg and pkg:getName() == packageName then
			return pkg, lockEntry
		end

		for _, config in ipairs(fs.scan(repoDir, "**" .. path.separator .. "lde.json")) do
			pkg = lde.Package.open(path.join(repoDir, path.dirname(config)))
			if pkg and pkg:getName() == packageName then
				return pkg, lockEntry
			end
		end

		-- Compatibility
		for _, config in ipairs(fs.scan(repoDir, "**" .. path.separator .. "lpm.json")) do
			pkg = lde.Package.open(path.join(repoDir, path.dirname(config)))
			if pkg and pkg:getName() == packageName then
				return pkg, lockEntry
			end
		end

		error("No lde.json with name '" .. packageName .. "' found in git repository")
	elseif depInfo.path then
		local localPackage, err = lde.Package.open(path.resolve(relativeTo, path.normalize(depInfo.path)),
			depInfo.rockspec)
		if not localPackage then
			error("Failed to load local dependency package for: " .. alias .. "\nError: " .. err)
		end
		return localPackage, { path = depInfo.path, name = depInfo.name, rockspec = depInfo.rockspec }
	elseif depInfo.archive then
		local archiveDir = lde.global.getOrInitArchive(depInfo.archive)
		local pkg, err = lde.Package.open(archiveDir, depInfo.rockspec)
		if not pkg then
			error("Failed to load archive dependency '" .. alias .. "': " .. (err or ""))
		end

		---@type lde.Lockfile.ArchiveDependency
		local lockEntry = { archive = depInfo.archive, name = depInfo.name, rockspec = depInfo.rockspec }

		return pkg, lockEntry
	elseif depInfo.luarocks then -- luarocks registry
		local pkg, lockEntry, err = lde.util.openLuarocksPackage(depInfo.luarocks, depInfo.version)
		if not pkg then
			error("Failed to resolve luarocks dep '" .. alias .. "': " .. (err or ""))
		end ---@cast lockEntry -nil

		lockEntry.name = depInfo.name
		return pkg, lockEntry
	elseif depInfo.version then -- lde registry
		lde.global.syncRegistry()

		local portfile, registryErr = lde.global.lookupRegistryPackage(packageName)
		if not portfile then
			error("Registry lookup failed for '" .. alias .. "': " .. registryErr)
		end

		local _, commit = lde.global.resolveRegistryVersion(portfile, depInfo.version)
		local repoDir = lde.global.getOrInitGitRepo(packageName, portfile.git, portfile.branch, commit)

		---@type lde.Lockfile.GitDependency
		local lockEntry = { git = portfile.git, commit = commit, branch = portfile.branch, name = depInfo.name }

		local pkg = lde.Package.open(repoDir, depInfo.rockspec)
		if pkg and pkg:getName() == packageName then
			return pkg, lockEntry
		end

		for _, config in ipairs(fs.scan(repoDir, "**" .. path.separator .. "lde.json")) do
			pkg = lde.Package.open(path.join(repoDir, path.dirname(config)))
			if pkg and pkg:getName() == packageName then
				return pkg, lockEntry
			end
		end

		error("No lde.json with name '" .. packageName .. "' found in registry package '" .. alias .. "'")
	else
		error("Unsupported dependency type for: " .. alias)
	end
end

--- Returns a string key that uniquely identifies a dependency's source.
---@param entry lde.Lockfile.Dependency
---@param pkg lde.Package
---@return string
local function sourceKey(entry, pkg)
	if entry.git then
		return "git:" .. entry.git .. "@" .. (entry.commit or "")
	elseif entry.path then
		return "path:" .. pkg.dir
	elseif entry.archive then
		return "archive:" .. entry.archive
	end
	return "unknown"
end

--- Recursively resolves all dependencies onto a flat stack.
--- Errors on duplicate names with differing sources.
---@param dependencies table<string, lde.Config.Dependency>
---@param relativeTo string
---@param stack table<string, { pkg: lde.Package, lock: lde.Lockfile.Dependency }>
---@param visiting table<string, boolean>
---@param rootLockfile lde.Lockfile?
local function collectDependencies(dependencies, relativeTo, stack, visiting, rootLockfile)
	for alias, depInfo in pairs(dependencies) do
		if visiting[alias] then
			goto continue
		end

		-- Use root lockfile entry if available to avoid re-resolving luarocks deps
		if rootLockfile then
			local locked = rootLockfile:getDependency(alias)
			if locked then depInfo = locked end
		end

		local pkg, lockEntry = dependencyToPackage(alias, depInfo, relativeTo)

		if stack[alias] then
			local existingKey = sourceKey(stack[alias].lock, stack[alias].pkg)
			local newKey = sourceKey(lockEntry, pkg)

			if existingKey ~= newKey then
				error(
					"Conflicting sources for dependency '" .. alias .. "':\n" ..
					"  " .. existingKey .. "\n" ..
					"  " .. newKey
				)
			end
		else
			stack[alias] = { pkg = pkg, lock = lockEntry }

			visiting[alias] = true
			collectDependencies(pkg:getDependencies(), pkg:getDir(), stack, visiting, rootLockfile)
			visiting[alias] = nil
		end

		::continue::
	end
end

---@type table<string, lde.Config.FeatureFlag>
local platformLookup = {
	["Windows"] = "windows",
	["Linux"] = "linux",
	["OSX"] = "macos"
}

-- Preallocate this for the main case where no features are passed
local basicFeatureTable = { platformLookup[jit.os] }

--- Adds the current platform ("windows", "linux", or "macos") to a features table.
---@param t lde.Config.FeatureFlag[]?
---@return lde.Config.FeatureFlag[]
local function addPlatformFeatures(t)
	if not t then
		return basicFeatureTable
	end

	t[#t + 1] = platformLookup[jit.os]
	return t
end

---@param package lde.Package
---@param dependencies table<string, lde.Config.Dependency>?
---@param relativeTo string?
---@param features lde.Config.FeatureFlag[]?
local function installDependencies(package, dependencies, relativeTo, features)
	features = addPlatformFeatures(features) -- features is not to be mutated from here on out
	local isRoot = dependencies == nil
	dependencies = dependencies or package:getDependencies()
	relativeTo = relativeTo or package.dir

	---@type table<string, true> # depname: true
	local enabledOptional = {}
	if features and package:readConfig().features then
		for _, featureName in ipairs(features) do
			local deps = package:readConfig().features[featureName]
			if deps then
				for _, depName in ipairs(deps) do
					enabledOptional[depName] = true
				end
			end
		end
	end

	local modulesDir = package:getModulesDir()

	-- Fast path: if target/.installed hash matches the current lockfile, skip all work
	if isRoot then
		local lockfilePath = package:getLockfilePath()
		local installedPath = path.join(modulesDir, ".installed")
		if fs.exists(lockfilePath) and fs.exists(installedPath) then
			local lockfileContent = fs.read(lockfilePath)
			if lockfileContent and fs.read(installedPath) == util.fnv1a(lockfileContent) then
				return
			end
		end
	end

	if not fs.exists(modulesDir) then
		fs.mkdir(modulesDir)
	end

	-- 1. Recursively collect all deps onto a flat stack, validating conflicts
	local stack = {}
	local rootLockfile = isRoot and package:readLockfile() or nil
	collectDependencies(dependencies, relativeTo, stack, {}, rootLockfile)

	-- 2. Install each resolved dependency (skip optional deps not enabled via features)
	for alias, entry in pairs(stack) do
		local depInfo = dependencies[alias]
		if depInfo and depInfo.optional and not enabledOptional[alias] then
			goto continue
		end
		local destinationPath = path.join(modulesDir, alias)
		if not fs.islink(destinationPath) then
			entry.pkg:build(destinationPath)
		end
		::continue::
	end

	-- 3. Write a single flat lockfile only for the root call (includes optional deps regardless)
	if isRoot then
		local lockEntries = {}
		for alias, entry in pairs(stack) do
			lockEntries[alias] = entry.lock
		end

		local lockfile = lde.Lockfile.new(package:getLockfilePath(), lockEntries)
		lockfile:save()

		local lockfileContent = fs.read(package:getLockfilePath())
		fs.write(path.join(modulesDir, ".installed"), util.fnv1a(lockfileContent))
	end
end

return installDependencies
