local path = require("path")
local fs = require("fs")
local process = require("process")

local global = require("lpm-core.global")
local Package = require("lpm-core.package")
local Lockfile = require("lpm-core.lockfile")

---@param package lpm.Package
---@param dependency lpm.Package
---@param alias string # The name to install under (may differ from dependency:getName() when aliasing)
local function installDependency(package, dependency, alias)
	-- Recursively install dependencies of the dependency first
	package:installDependencies(dependency:getDependencies(), dependency:getDir())

	local modulesDir = package:getModulesDir()
	local destinationPath = path.join(modulesDir, alias)
	if fs.islink(destinationPath) then
		-- If its a symlink it should already be at the latest version.
		return
	end

	-- Otherwise, always assume it is dirty and needs to be updated.
	-- In the future this could potentially do a modification diff.
	dependency:build(destinationPath)
end

--- Gets a proper lpm.Package instance from dependency info, and returns the
--- resolved lockfile entry for it.
---@param alias string # The key in the dependencies table (used as the install name)
---@param depInfo lpm.Config.Dependency
---@param relativeTo string
---@return lpm.Package, lpm.Lockfile.Dependency
local function dependencyToPackage(alias, depInfo, relativeTo)
	-- depInfo.package overrides the lookup name (aliasing support)
	local packageName = depInfo.package or alias

	if depInfo.git then
		local repoDir = global.getOrInitGitRepo(packageName, depInfo.git, depInfo.branch, depInfo.commit)

		-- Resolve the exact HEAD commit for pinning in the lockfile
		local ok, output = process.exec("git", { "rev-parse", "HEAD" }, { cwd = repoDir })
		local resolvedCommit = (ok and output) and string.gsub(output, "%s+$", "") or depInfo.commit
		if not resolvedCommit then
			error("Failed to resolve HEAD commit for git dependency")
		end

		---@type lpm.Lockfile.GitDependency
		local lockEntry = {
			git = depInfo.git,
			commit = resolvedCommit,
			branch = depInfo.branch,
			package = depInfo.package
		}

		local gitDependencyPackage = Package.open(repoDir)
		if gitDependencyPackage and gitDependencyPackage:getName() == packageName then
			return gitDependencyPackage, lockEntry
		end

		for _, config in ipairs(fs.scan(repoDir, "**" .. path.separator .. "lpm.json")) do
			local parentDir = path.join(repoDir, path.dirname(config))

			gitDependencyPackage = Package.open(parentDir)
			if gitDependencyPackage and gitDependencyPackage:getName() == packageName then
				return gitDependencyPackage, lockEntry
			end
		end

		error("No lpm.json with name '" .. packageName .. "' found in git repository")
	elseif depInfo.path then
		local normalized = path.normalize(depInfo.path)
		local localPackage, err = Package.open(path.resolve(relativeTo, normalized))

		if not localPackage then
			error("Failed to load local dependency package for: " .. alias .. "\nError: " .. err)
		end

		---@type lpm.Lockfile.PathDependency
		local lockEntry = {
			path = depInfo.path,
			package = depInfo.package
		}

		return localPackage, lockEntry
	elseif depInfo.version then
		-- Registry dependency: sync registry, look up portfile, resolve to git+commit
		global.syncRegistry()

		local portfile, registryErr = global.lookupRegistryPackage(packageName)
		if not portfile then
			error("Registry lookup failed for '" .. alias .. "': " .. registryErr)
		end

		local _, commit = global.resolveRegistryVersion(portfile, depInfo.version)

		local repoDir = global.getOrInitGitRepo(packageName, portfile.git, portfile.branch, commit)

		---@type lpm.Lockfile.GitDependency
		local lockEntry = {
			git = portfile.git,
			commit = commit,
			branch = portfile.branch,
			package = depInfo.package
		}

		local registryPackage = Package.open(repoDir)
		if registryPackage and registryPackage:getName() == packageName then
			return registryPackage, lockEntry
		end

		for _, config in ipairs(fs.scan(repoDir, "**" .. path.separator .. "lpm.json")) do
			local parentDir = path.join(repoDir, path.dirname(config))
			registryPackage = Package.open(parentDir)
			if registryPackage and registryPackage:getName() == packageName then
				return registryPackage, lockEntry
			end
		end

		error("No lpm.json with name '" .. packageName .. "' found in registry package '" .. alias .. "'")
	else
		error("Unsupported dependency type for: " .. alias)
	end
end

---@param package lpm.Package
---@param dependencies table<string, lpm.Config.Dependency>?
---@param relativeTo string? # Directory to resolve relative paths from
local function installDependencies(package, dependencies, relativeTo)
	local isTopLevel = dependencies == nil
	dependencies = dependencies or package:getDependencies()
	relativeTo = relativeTo or package.dir

	local modulesDir = package:getModulesDir()
	if not fs.exists(modulesDir) then
		fs.mkdir(modulesDir)
	end

	local lockEntries = {}
	for name, depInfo in pairs(dependencies) do
		local dependencyPackage, lockEntry = dependencyToPackage(name, depInfo, relativeTo)
		installDependency(package, dependencyPackage, name)
		lockEntries[name] = lockEntry
	end

	if isTopLevel then
		Lockfile.new(package:getLockfilePath(), lockEntries):save()
	end
end

return installDependencies
