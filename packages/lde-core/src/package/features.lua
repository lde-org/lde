--- Feature flags: a manifest lists per-flag effects -- dependency aliases to enable and `<pkg>.<module>` names to drop from the bundle when bundling (never from `target/` in dev); platform flags are always on.

const fs = require("fs")
const json = require("json")
const path = require("path")

const features = {}

--- Platform flag by jit.os. BSD is listed although no flag existed for it before, so a manifest gating on `bsd` can turn it on.
---@type table<string, string>
const OS_FLAGS = {
	Windows = "windows",
	Linux = "linux",
	OSX = "macos",
	BSD = "bsd"
}

---@class lde.Package.Config.FeatureDefinition
---@field deps string[]? # optional dependency aliases this flag enables
---@field modules string[]? # module paths below the module dir that this flag drops

---@alias lde.Package.Config.FeatureDeclarations table<string, string[]>

---@alias lde.Package.Config.FeatureDefinitions table<string, lde.Package.Config.FeatureDefinition>

function features.platformFlags()
	local os = OS_FLAGS[jit.os]
	if not os then return {} end
	if os == "windows" then return { os } end
	return { os, "unix" }
end

---@param entry string
---@param packageName string?
---@return boolean
local function isModuleName(entry, packageName)
	if not packageName then return false end
	local prefix = packageName .. "."
	return entry:sub(1, #prefix) == prefix and #entry > #prefix
end

--- A flag whose value is not a list is rejected rather than ignored: dropping it would silently ship files the package asked to exclude.
---@param declared table<string, any>?
---@param packageName string? # the declaring package, needed to read module names
function features.parse(declared, packageName)
	if type(declared) ~= "table" then return nil end

	---@type table<string, lde.Package.Config.FeatureDefinition>
	local normalized = {}
	for flag, def in pairs(declared) do
		if type(def) ~= "table" or def[1] == nil then
			require("lde-core.error").raise(
				"Feature '" .. tostring(flag) .. "' in " .. (packageName or "the manifest")
				.. " must be a list, e.g. \"" .. tostring(flag) .. "\": [\"dep\", \""
				.. (packageName or "package") .. ".some.module\"]"
			)
		end

		---@type lde.Package.Config.FeatureDefinition
		const split = {}
		for _, entry in ipairs(def) do
			if isModuleName(entry, packageName) then
				-- Offset is always in range: only reachable with a prefix.
				local modulePath = entry:sub(#packageName + 2):gsub("%.", "/")
				split.modules = split.modules or {}
				split.modules[#split.modules + 1] = modulePath
			else
				split.deps = split.deps or {}
				split.deps[#split.deps + 1] = entry
			end
		end
		normalized[flag] = split
	end
	return normalized
end

---@param pkg lde.Package
function features.of(pkg)
	return features.parse(pkg:readConfig().features, pkg:getName())
end

---@param defs table<string, lde.Package.Config.FeatureDefinition>? # normalized, from parse()/of()
---@param requested string[]? # as the dependency entries declared them
function features.enabled(defs, requested)
	---@type lde.Package.Config.FeatureDefinition[]
	local on = {}
	if not defs then return on end

	---@param flags string[]
	local function turnOn(flags)
		for _, flag in ipairs(flags) do
			const def = defs[flag]
			if def then on[#on + 1] = def end
		end
	end

	turnOn(features.platformFlags())
	if requested then turnOn(requested) end

	return on
end

---@param defs table<string, lde.Package.Config.FeatureDefinition>? # normalized
---@param requested string[]?
function features.enabledDependencies(defs, requested)
	---@type table<string, true>
	const enabled = {}
	for _, def in ipairs(features.enabled(defs, requested)) do
		for _, alias in ipairs(def.deps or {}) do
			enabled[alias] = true
		end
	end
	return enabled
end

--- Sorted flags on for `build:feature(name)`: platform flags always, plus every requested flag even when undeclared (a build script may be the only thing gating on it).
---@param defs table<string, lde.Package.Config.FeatureDefinition>? # normalized, unused beyond presence
---@param requested string[]?
function features.enabledFlags(defs, requested)
	---@type string[], table<string, boolean>
	local flags, seen = {}, {}

	---@param flag string
	local function add(flag)
		if not seen[flag] then
			seen[flag] = true
			flags[#flags + 1] = flag
		end
	end

	for _, flag in ipairs(features.platformFlags()) do add(flag) end
	for _, flag in ipairs(requested or {}) do add(flag) end

	table.sort(flags)
	return flags
end

--- Folds a file path to the module name `require()` would resolve it as (`raw/windows.lua`, `raw/windows/init.lua` and `raw/windows.so` all give `raw/windows`).
---@param relativePath string
local function modulePathOf(relativePath)
	local modulePath = relativePath:gsub("\\", "/"):gsub("^%./", "")
	modulePath = modulePath:gsub("%.[^./]+$", "")
	modulePath = modulePath:gsub("/init$", "")
	return modulePath
end

--- Sorted, de-duplicated: the result goes into the lockfile, so an unstable list would churn it on every install.
---@param defs table<string, lde.Package.Config.FeatureDefinition>? # normalized
---@param requested string[]?
---@return string[]? excludes # nil when nothing is excluded
function features.excludes(defs, requested)
	local seen, list = {}, {}
	for _, def in ipairs(features.enabled(defs, requested)) do
		for _, modulePath in ipairs(def.modules or {}) do
			if modulePath ~= "" and not seen[modulePath] then
				seen[modulePath] = true
				list[#list + 1] = modulePath
			end
		end
	end
	if #list == 0 then return nil end
	table.sort(list)
	return list
end

---@param relativePath string # relative to the package's module dir; any separator
---@param excludes string[]?
---@return boolean
function features.isExcluded(relativePath, excludes)
	if not excludes or #excludes == 0 then return false end

	local modulePath = modulePathOf(relativePath)
	for _, excluded in ipairs(excludes) do
		if excluded == modulePath then return true end
	end
	return false
end

---@param relativePaths string[]

--- Fallback for a package built outside an install (`lde compile` on itself), where only platform flags are known; inside an install `Package:getFeatures` has the recorded flags.
---@param pkg lde.Package
---@return string[] flags
function features.ofPackage(pkg)
	const explicit = pkg.features
	if explicit then return explicit end
	return features.enabledFlags(features.of(pkg), nil)
end

--- An alias rather than a class so both `lde.Lockfile.Dependency` and a hand-built `{ exclude = {...} }` satisfy it.
---@alias lde.Package.FeatureLockEntry
--- | { features: string[]?, exclude: string[]? }
--- | lde.Lockfile.Dependency

--- Prefers the dependency's live manifest (symlinked next to its module dir); falls back to the locked list, the only reachable source for copied dependencies (build.lua) whose manifest is not under `target/`.
---@param modulesDir string
---@param alias string
---@param lockEntry lde.Package.FeatureLockEntry?
---@return string[]? excludes
function features.excludesFor(modulesDir, alias, lockEntry)
	const content = fs.read(path.join(modulesDir, alias, "..", "lde.json"))
	if content then
		const ok, decoded = pcall(json.decode, content)
		if ok and type(decoded) == "table" then
			local defs = features.parse(decoded.features, decoded.name or alias)
			if defs then
				return features.excludes(defs, lockEntry?.features)
			end
		end
	end

	return lockEntry ? lockEntry.exclude : nil
end

---@param package lde.Package
---@param requested string[]? # extra flags for the package itself
---@return fun(alias: string): string[]?
function features.resolverFor(package, requested)
	local modulesDir = package:getModulesDir()
	const mainName = package:getName()
	local lockfile = package:readLockfile()
	const lockDeps = lockfile?.raw?.dependencies ?? {}
	const rootExcludes = features.excludes(features.of(package), requested)

	return function(alias)
		if alias == mainName then return rootExcludes end
		return features.excludesFor(modulesDir, alias, lockDeps[alias])
	end
end

return features
