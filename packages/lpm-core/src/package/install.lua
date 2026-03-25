local path = require("path")
local fs = require("fs")
local git = require("git")

local global = require("lpm-core.global")
local Package = require("lpm-core.package")
local Lockfile = require("lpm-core.lockfile")

---@param alias string
---@param depInfo lpm.Config.Dependency
---@param relativeTo string
---@return lpm.Package, lpm.Lockfile.Dependency
local function dependencyToPackage(alias, depInfo, relativeTo)
	local packageName = depInfo.name or alias

	if depInfo.git then
		local repoDir = global.getOrInitGitRepo(packageName, depInfo.git, depInfo.branch, depInfo.commit)

		local ok, output = git.getCommitHash(repoDir)
		local resolvedCommit = (ok and output) and string.gsub(output, "%s+$", "") or depInfo.commit
		if not resolvedCommit then
			error("Failed to resolve HEAD commit for git dependency")
		end

		---@type lpm.Lockfile.GitDependency
		local lockEntry = { git = depInfo.git, commit = resolvedCommit, branch = depInfo.branch, name = depInfo.name }

		local pkg = Package.open(repoDir, depInfo.rockspec)
		if pkg and pkg:getName() == packageName then return pkg, lockEntry end

		for _, config in ipairs(fs.scan(repoDir, "**" .. path.separator .. "lpm.json")) do
			pkg = Package.open(path.join(repoDir, path.dirname(config)))
			if pkg and pkg:getName() == packageName then return pkg, lockEntry end
		end

		error("No lpm.json with name '" .. packageName .. "' found in git repository")
	elseif depInfo.path then
		local localPackage, err = Package.open(path.resolve(relativeTo, path.normalize(depInfo.path)), depInfo.rockspec)
		if not localPackage then
			error("Failed to load local dependency package for: " .. alias .. "\nError: " .. err)
		end
		return localPackage, { path = depInfo.path, name = depInfo.name }
	elseif depInfo.version then
		global.syncRegistry()

		local portfile, registryErr = global.lookupRegistryPackage(packageName)
		if not portfile then
			error("Registry lookup failed for '" .. alias .. "': " .. registryErr)
		end

		local _, commit = global.resolveRegistryVersion(portfile, depInfo.version)
		local repoDir = global.getOrInitGitRepo(packageName, portfile.git, portfile.branch, commit)

		---@type lpm.Lockfile.GitDependency
		local lockEntry = { git = portfile.git, commit = commit, branch = portfile.branch, name = depInfo.name }

		local pkg = Package.open(repoDir, depInfo.rockspec)
		if pkg and pkg:getName() == packageName then return pkg, lockEntry end

		for _, config in ipairs(fs.scan(repoDir, "**" .. path.separator .. "lpm.json")) do
			pkg = Package.open(path.join(repoDir, path.dirname(config)))
			if pkg and pkg:getName() == packageName then return pkg, lockEntry end
		end

		error("No lpm.json with name '" .. packageName .. "' found in registry package '" .. alias .. "'")
	else
		error("Unsupported dependency type for: " .. alias)
	end
end

--- Returns a string key that uniquely identifies a dependency's source.
---@param entry lpm.Lockfile.Dependency
---@return string
local function sourceKey(entry)
	if entry.git then
		return "git:" .. entry.git .. "@" .. (entry.commit or "")
	elseif entry.path then
		return "path:" .. entry.path
	end
	return "unknown"
end

--- Recursively resolves all dependencies onto a flat stack.
--- Errors on duplicate names with differing sources.
---@param dependencies table<string, lpm.Config.Dependency>
---@param relativeTo string
---@param stack table<string, { pkg: lpm.Package, lock: lpm.Lockfile.Dependency }>
---@param visiting table<string, boolean>
local function collectDependencies(dependencies, relativeTo, stack, visiting)
	for alias, depInfo in pairs(dependencies) do
		if visiting[alias] then
			-- Already mid-resolution (cycle), skip
			goto continue
		end

		local pkg, lockEntry = dependencyToPackage(alias, depInfo, relativeTo)

		if stack[alias] then
			-- Already seen — validate source matches
			if sourceKey(stack[alias].lock) ~= sourceKey(lockEntry) then
				error(
					"Conflicting sources for dependency '" .. alias .. "':\n" ..
					"  " .. sourceKey(stack[alias].lock) .. "\n" ..
					"  " .. sourceKey(lockEntry)
				)
			end
		else
			stack[alias] = { pkg = pkg, lock = lockEntry }

			-- Recurse into this dependency's own dependencies
			visiting[alias] = true
			collectDependencies(pkg:getDependencies(), pkg:getDir(), stack, visiting)
			visiting[alias] = nil
		end

		::continue::
	end
end

---@param package lpm.Package
---@param dependencies table<string, lpm.Config.Dependency>?
---@param relativeTo string?
local function installDependencies(package, dependencies, relativeTo)
	local isRoot = dependencies == nil
	dependencies = dependencies or package:getDependencies()
	relativeTo = relativeTo or package.dir

	local modulesDir = package:getModulesDir()
	if not fs.exists(modulesDir) then
		fs.mkdir(modulesDir)
	end

	-- 1. Recursively collect all deps onto a flat stack, validating conflicts
	local stack = {}
	collectDependencies(dependencies, relativeTo, stack, {})

	-- 2. Install each resolved dependency
	for alias, entry in pairs(stack) do
		local destinationPath = path.join(modulesDir, alias)
		if not fs.islink(destinationPath) then
			entry.pkg:build(destinationPath)
		end
	end

	-- 3. Write a single flat lockfile only for the root call
	if isRoot then
		local lockEntries = {}
		for alias, entry in pairs(stack) do
			lockEntries[alias] = entry.lock
		end
		Lockfile.new(package:getLockfilePath(), lockEntries):save()
	end
end

return installDependencies
