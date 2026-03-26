local fs = require("fs")
local path = require("path")
local git = require("git")
local util = require("util")

local lpm = require("lpm-core")

---@param alias string
---@param depInfo lpm.Config.Dependency
---@param relativeTo string
---@return lpm.Package, lpm.Lockfile.Dependency
local function dependencyToPackage(alias, depInfo, relativeTo)
	local packageName = depInfo.name or alias

	if depInfo.git then
		local repoDir = lpm.global.getOrInitGitRepo(packageName, depInfo.git, depInfo.branch, depInfo.commit)

		local resolvedCommit = depInfo.commit
		if not resolvedCommit then
			local ok, output = git.getCommitHash(repoDir)
			resolvedCommit = (ok and output) and string.gsub(output, "%s+$", "") or nil
			if not resolvedCommit then
				error("Failed to resolve HEAD commit for git dependency")
			end
		end

		---@type lpm.Lockfile.GitDependency
		local lockEntry = {
			git = depInfo.git,
			commit = resolvedCommit,
			branch = depInfo.branch,
			name = depInfo.name,
			rockspec =
				depInfo.rockspec
		}

		local pkg = lpm.Package.open(repoDir, depInfo.rockspec)
		if pkg and pkg:getName() == packageName then
			return pkg, lockEntry
		end

		for _, config in ipairs(fs.scan(repoDir, "**" .. path.separator .. "lpm.json")) do
			pkg = lpm.Package.open(path.join(repoDir, path.dirname(config)))
			if pkg and pkg:getName() == packageName then
				return pkg, lockEntry
			end
		end

		error("No lpm.json with name '" .. packageName .. "' found in git repository")
	elseif depInfo.path then
		local localPackage, err = lpm.Package.open(path.resolve(relativeTo, path.normalize(depInfo.path)),
			depInfo.rockspec)
		if not localPackage then
			error("Failed to load local dependency package for: " .. alias .. "\nError: " .. err)
		end
		return localPackage, { path = depInfo.path, name = depInfo.name, rockspec = depInfo.rockspec }
	elseif depInfo.archive then
		local archiveDir = lpm.global.getOrInitArchive(depInfo.archive)
		local pkg, err = lpm.Package.open(archiveDir, depInfo.rockspec)
		if not pkg then
			error("Failed to load archive dependency '" .. alias .. "': " .. (err or ""))
		end
		---@type lpm.Lockfile.ArchiveDependency
		local lockEntry = { archive = depInfo.archive, name = depInfo.name, rockspec = depInfo.rockspec }
		return pkg, lockEntry
	elseif depInfo.luarocks then -- luarocks registry
		local pkg, lockEntry, err = lpm.util.openLuarocksPackage(depInfo.luarocks, depInfo.version)
		if not pkg then
			error("Failed to resolve luarocks dep '" .. alias .. "': " .. (err or ""))
		end
		if lockEntry then lockEntry.name = depInfo.name end
		return pkg, lockEntry
	elseif depInfo.version then -- lpm registry
		lpm.global.syncRegistry()

		local portfile, registryErr = lpm.global.lookupRegistryPackage(packageName)
		if not portfile then
			error("Registry lookup failed for '" .. alias .. "': " .. registryErr)
		end

		local _, commit = lpm.global.resolveRegistryVersion(portfile, depInfo.version)
		local repoDir = lpm.global.getOrInitGitRepo(packageName, portfile.git, portfile.branch, commit)

		---@type lpm.Lockfile.GitDependency
		local lockEntry = { git = portfile.git, commit = commit, branch = portfile.branch, name = depInfo.name }

		local pkg = lpm.Package.open(repoDir, depInfo.rockspec)
		if pkg and pkg:getName() == packageName then
			return pkg, lockEntry
		end

		for _, config in ipairs(fs.scan(repoDir, "**" .. path.separator .. "lpm.json")) do
			pkg = lpm.Package.open(path.join(repoDir, path.dirname(config)))
			if pkg and pkg:getName() == packageName then
				return pkg, lockEntry
			end
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
	elseif entry.archive then
		return "archive:" .. entry.archive
	end
	return "unknown"
end

--- Recursively resolves all dependencies onto a flat stack.
--- Errors on duplicate names with differing sources.
---@param dependencies table<string, lpm.Config.Dependency>
---@param relativeTo string
---@param stack table<string, { pkg: lpm.Package, lock: lpm.Lockfile.Dependency }>
---@param visiting table<string, boolean>
---@param rootLockfile lpm.Lockfile?
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
			if sourceKey(stack[alias].lock) ~= sourceKey(lockEntry) then
				error(
					"Conflicting sources for dependency '" .. alias .. "':\n" ..
					"  " .. sourceKey(stack[alias].lock) .. "\n" ..
					"  " .. sourceKey(lockEntry)
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

---@param package lpm.Package
---@param dependencies table<string, lpm.Config.Dependency>?
---@param relativeTo string?
local function installDependencies(package, dependencies, relativeTo)
	local isRoot = dependencies == nil
	dependencies = dependencies or package:getDependencies()
	relativeTo = relativeTo or package.dir

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
		local lockfile = lpm.Lockfile.new(package:getLockfilePath(), lockEntries)
		lockfile:save()
		local lockfileContent = fs.read(package:getLockfilePath())
		fs.write(path.join(modulesDir, ".installed"), util.fnv1a(lockfileContent))
	end
end

return installDependencies
