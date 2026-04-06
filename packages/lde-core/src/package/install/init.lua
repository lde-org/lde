local fs              = require("fs")
local path            = require("path")
local util            = require("util")

local lde             = require("lde-core")

local resolveGit      = require("lde-core.package.install.git")
local resolvePath     = require("lde-core.package.install.path")
local resolveArchive  = require("lde-core.package.install.archive")
local resolveLuarocks = require("lde-core.package.install.luarocks")
local resolveRegistry = require("lde-core.package.install.registry")

--- Copies config-only flags (optional, features) from a config entry onto a lock entry.
---@param lockEntry lde.Lockfile.Dependency
---@param depInfo lde.Package.Config.Dependency
---@return lde.Lockfile.Dependency
local function withConfigFlags(lockEntry, depInfo)
	lockEntry.optional = depInfo.optional
	lockEntry.features = depInfo.features
	return lockEntry
end

---@param alias string
---@param depInfo lde.Package.Config.Dependency
---@param relativeTo string
---@return lde.Package, lde.Lockfile.Dependency
local function dependencyToPackage(alias, depInfo, relativeTo)
	local packageName = depInfo.name or alias
	local pkg, lockEntry

	if depInfo.git then ---@cast depInfo lde.Package.Config.GitDependency
		pkg, lockEntry = resolveGit(packageName, depInfo)
	elseif depInfo.path then ---@cast depInfo lde.Package.Config.PathDependency
		pkg, lockEntry = resolvePath(alias, depInfo, relativeTo)
	elseif depInfo.archive then ---@cast depInfo lde.Package.Config.ArchiveDependency
		pkg, lockEntry = resolveArchive(alias, depInfo)
	elseif depInfo.luarocks then ---@cast depInfo lde.Package.Config.LuarocksDependency
		pkg, lockEntry = resolveLuarocks(alias, depInfo)
	elseif depInfo.version then ---@cast depInfo lde.Package.Config.RegistryDependency
		pkg, lockEntry = resolveRegistry(alias, packageName, depInfo)
	else
		error("Unsupported dependency type for: " .. alias)
	end

	return pkg, withConfigFlags(lockEntry, depInfo)
end

--- Returns a string key that uniquely identifies a dependency's source.
---@param entry lde.Lockfile.Dependency
---@param pkg lde.Package
---@return string
local function sourceKey(entry, pkg)
	if entry.git then return "git:" .. entry.git .. "@" .. (entry.commit or "") end
	if entry.path then return "path:" .. pkg.dir end
	if entry.archive then return "archive:" .. entry.archive end
	return "unknown"
end

---@class lde.install.Context
---@field relativeTo string
---@field stack table<string, { pkg: lde.Package, lock: lde.Lockfile.Dependency }>
---@field visiting table<string, boolean>
---@field rootLockfile lde.Lockfile?

--- Recursively resolves all dependencies onto a flat stack.
--- Errors on duplicate names with differing sources.
---@param dependencies table<string, lde.Package.Config.Dependency>
---@param ctx lde.install.Context
local function collectDependencies(dependencies, ctx)
	for alias, depInfo in pairs(dependencies) do
		if ctx.visiting[alias] then goto continue end

		-- Use root lockfile entry if available to avoid re-resolving luarocks deps
		if ctx.rootLockfile then
			local locked = ctx.rootLockfile:getDependency(alias)
			if locked then depInfo = withConfigFlags(locked, depInfo) end
		end

		local pkg, lockEntry = dependencyToPackage(alias, depInfo, ctx.relativeTo)

		if ctx.stack[alias] then
			local existingKey = sourceKey(ctx.stack[alias].lock, ctx.stack[alias].pkg)
			local newKey = sourceKey(lockEntry, pkg)
			if existingKey ~= newKey then
				error("Conflicting sources for dependency '" .. alias .. "':\n  " .. existingKey .. "\n  " .. newKey)
			end
		else
			ctx.stack[alias] = { pkg = pkg, lock = lockEntry }
			ctx.visiting[alias] = true
			local parentRelativeTo = ctx.relativeTo
			ctx.relativeTo = pkg:getDir()
			collectDependencies(pkg:getDependencies(), ctx)
			ctx.relativeTo = parentRelativeTo
			ctx.visiting[alias] = nil
		end

		::continue::
	end
end

---@type table<string, lde.Package.Config.FeatureFlag>
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

--- Saves the lockfile and writes the .installed hash marker.
---@param pkg lde.Package
---@param stack table<string, { pkg: lde.Package, lock: lde.Lockfile.Dependency }>
---@param modulesDir string
local function commitLockfile(pkg, stack, modulesDir)
	local lockEntries = {}
	for alias, entry in pairs(stack) do
		lockEntries[alias] = entry.lock
	end

	local lockfile = lde.Lockfile.new(pkg:getLockfilePath(), lockEntries)
	lockfile:save()

	local content = assert(fs.read(pkg:getLockfilePath()), "Failed to read " .. pkg:getLockfilePath())
	fs.write(path.join(modulesDir, ".installed"), util.fnv1a(content))
end

---@param package lde.Package
---@param dependencies table<string, lde.Package.Config.Dependency>?
---@param relativeTo string?
---@param features lde.Package.Config.FeatureFlag[]?
local function installDependencies(package, dependencies, relativeTo, features)
	local isRoot = dependencies == nil
	dependencies = dependencies or package:getDependencies()
	relativeTo = relativeTo or package.dir

	features = features or {}
	features[#features + 1] = platformLookup[jit.os]

	local modulesDir = package:getModulesDir()

	-- Fast path: if target/.installed hash matches the current lockfile, skip all work
	if isRoot then
		local installedPath = path.join(modulesDir, ".installed")
		local lockfilePath = package:getLockfilePath()
		if fs.exists(lockfilePath) and fs.exists(installedPath) then
			local content = fs.read(lockfilePath)
			if content and fs.read(installedPath) == util.fnv1a(content) then return end
		end
	end

	if not fs.exists(modulesDir) then fs.mkdir(modulesDir) end

	local ctx = {
		relativeTo = relativeTo,
		stack = {},
		visiting = {},
		rootLockfile = isRoot and package:readLockfile() or nil
	}

	-- This collects all deps to a flat stack and validates versioning problems.
	collectDependencies(dependencies, ctx)

	-- Gets which features are enabled (+ OS specific features)
	local enabledOptional = resolveEnabledOptional(package, features)

	for alias, entry in pairs(ctx.stack) do
		local depInfo = dependencies[alias]

		-- Optional, skip..
		if depInfo and depInfo.optional and not enabledOptional[alias] then
			goto continue
		end

		local dest = path.join(modulesDir, alias)

		-- Has a build script, needs to run.
		if not fs.islink(dest) then
			entry.pkg:build(dest)
		end

		::continue::
	end

	if isRoot then
		commitLockfile(package, ctx.stack, modulesDir)
	end
end

return installDependencies
