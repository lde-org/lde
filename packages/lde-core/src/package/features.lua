--- Feature flags: which flags are on for a package, what each flag turns on,
--- and which of the package's own modules a flag drops from a bundle.
---
--- A manifest declares a flag's effect as a plain list under `features`:
---
---   "features": {
---     "windows": ["winapi"],              -- a dependency alias
---     "unix":    ["luaposix", "fs.raw.windows"]
---   }
---
--- An entry starting with the package's own name and a dot -- written exactly
--- the way `require()` spells the module -- names one of the package's own
--- modules and is dropped from the bundle when the flag is on. Anything else is
--- a dependency alias to enable.
---
--- The two cannot be confused, and that is provable rather than conventional:
--- package names are validated to `^[a-z][a-z0-9_-]*[a-z0-9]$` (see
--- `Registry:validateName`), so a package name can never contain a dot, and
--- `<packageName>.` can never be the start of a dependency alias.
---
--- The effect belongs to the package that declares it, never to a package that
--- depends on it: a consumer only ever *names* flags, on its dependency entry
--- (`{ "path": "../fs", "features": ["unix"] }`) or by running on a platform
--- whose flag lde turns on by itself.
---
--- Platform flags are always on, in the platform's own words, so a package can
--- gate its own files without every consumer repeating itself:
---
---   windows          jit.os == "Windows"
---   linux/macos/bsd  the matching non-Windows OS
---   unix             any non-Windows OS, so "everything but the Win32 backend"
---                    is one entry rather than one per Unix
---
--- Module exclusion is what lets a package keep several platform backends in
--- one repository and still ship only the one that runs: `fs` drops its Win32
--- backend under `unix`, and its POSIX/BSD/macOS backends under `windows`.
---
--- Exclusion matches on the *module* a file implements, not on its filename, so
--- one entry covers every form that module can ship in: naming `fs.native.core`
--- drops `native/core.lua`, `native/core/init.lua`, and a prebuilt
--- `native/core.so`/`.dll`/`.dylib` alike -- any extension, Lua or native.
---
--- IMPORTANT: exclusions are applied when a package is bundled -- `lde bundle`,
--- `lde compile`, `lde bloat` -- so the shipped artifact carries only the
--- selected files. They are deliberately NOT applied to `target/` in dev: a
--- dependency is symlinked there, and dropping files would mean copying every
--- dependency just to run it. A build script decides for itself whether to
--- produce a gated artifact, via `build:feature(name)`.
---
--- Shape of the data, which matters because it decides who needs the package
--- name: `parse` is the only function that needs it, and it turns a manifest's
--- raw lists into `{ deps = {...}, modules = { "raw/windows" } }` with the
--- module prefix already stripped. Everything downstream -- `enabled`,
--- `enabledDependencies`, `enabledFlags`, `excludes` -- works on that and never
--- sees a package name again.

const fs = require("fs")
const json = require("json")
const path = require("path")

const features = {}

--- The flag naming the platform being installed on, by jit.os. BSD is listed
--- explicitly: it had no flag before, so a manifest gating on `bsd` had no way
--- to ever turn it on.
---@type table<string, string>
const OS_FLAGS = {
	Windows = "windows",
	Linux = "linux",
	OSX = "macos",
	BSD = "bsd"
}

--- A feature's effect, split into the two things a flag can turn on. This is
--- the normalized form; a manifest declares a plain list, not this.
---@class lde.Package.Config.FeatureDefinition
---@field deps string[]? # optional dependency aliases this flag enables
---@field modules string[]? # module paths below the module dir that this flag drops

--- A manifest's `features` as it is written: a flag and the entries it turns on, before
--- `features.parse` splits them into a dependency alias and a module of the package's own.
---@alias lde.Package.Config.FeatureDeclarations table<string, string[]>

---@alias lde.Package.Config.FeatureDefinitions table<string, lde.Package.Config.FeatureDefinition>

--- Flags lde always turns on for every package: the OS's own flag, plus `unix`
--- on every non-Windows platform.
function features.platformFlags()
	local os = OS_FLAGS[jit.os]
	if not os then return {} end
	if os == "windows" then return { os } end
	return { os, "unix" }
end

--- True when an entry names one of the package's own modules.
---@param entry string
---@param packageName string?
---@return boolean
local function isModuleName(entry, packageName)
	if not packageName then return false end
	local prefix = packageName .. "."
	return entry:sub(1, #prefix) == prefix and #entry > #prefix
end

--- Turns a manifest's `features` table into the normalized form.
---
--- An entry starting with `<packageName>.` is a module of this package and
--- becomes a module path below the module dir (`fs.raw.windows` -> `raw/windows`);
--- anything else is a dependency alias.
---
--- A flag whose value is not a list is rejected rather than ignored: silently
--- dropping it would leave a package quietly shipping files it asked to exclude.
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
				-- Strip the prefix and map dots onto directories, the same way
				-- require() resolves the name. Only reachable with a prefix, so
				-- the offset is always in range.
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

--- The normalized `features` table of a package, or nil when it declares none.
--- A rockspec-backed package has no manifest and therefore no features.
---@param pkg lde.Package
function features.of(pkg)
	return features.parse(pkg:readConfig().features, pkg:getName())
end

--- The flags that are on for a package: the platform's own, plus the ones the
--- package's dependents named on their dependency entries.
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

--- The optional dependency aliases the enabled flags turn on.
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

--- The names of the enabled flags, sorted. This is what a build script sees via
--- `build:feature(name)`.
---
--- Unlike `enabled()` -- which only reports flags a manifest gave an *effect*
--- to, because it needs the definition to know what to turn on -- this is the
--- plain set of flags that are on:
---
---   * the platform's own flags, always, whether or not the manifest mentions
---     them. `build:feature("linux")` has to be true on Linux even in a package
---     that declares no `linux` entry.
---   * every flag the dependents asked for, declared or not. A build script is
---     allowed to be the only thing a flag drives -- `if build:feature("vulkan")
---     then build:cc{...} end` with no `features` entry at all -- so requesting
---     it must be enough.
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

--- The module paths a file in the package answers to: its path below the module
--- dir, without the extension, and with a trailing `/init` folded away. This is
--- the mapping `package.path` performs, in reverse -- `raw/windows.lua`,
--- `raw/windows/init.lua` and a prebuilt `raw/windows.so` are all the module
--- `raw/windows`, so one name covers every form a module can ship in.
---@param relativePath string
local function modulePathOf(relativePath)
	local modulePath = relativePath:gsub("\\", "/"):gsub("^%./", "")
	modulePath = modulePath:gsub("%.[^./]+$", "")
	modulePath = modulePath:gsub("/init$", "")
	return modulePath
end

--- The module paths the enabled flags drop from a bundle. Sorted and
--- de-duplicated: the result is written into the lockfile, and an unstable list
--- would churn the lockfile on every install.
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

--- True when a package-relative file implements one of the excluded modules.
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

--- The subset of `relativePaths` the excluded modules leave alone.
---@param relativePaths string[]
---@param excludes string[]?
function features.filter(relativePaths, excludes)
	if not excludes or #excludes == 0 then return relativePaths end

	---@type string[]
	const kept = {}
	for _, relativePath in ipairs(relativePaths) do
		if not features.isExcluded(relativePath, excludes) then
			kept[#kept + 1] = relativePath
		end
	end
	return kept
end

--- The package's own flags, as a build script sees them through
--- `build:feature(name)`. Mirrors `Package:setFeatures`/`getFeatures` in
--- lde-core, which is where the installer records the flags a dependency entry
--- asked for -- this is the fallback for a package built outside an install
--- (e.g. `lde compile` on itself), where only the platform's flags are known.
---@param pkg lde.Package
---@return string[] flags
function features.ofPackage(pkg)
	const explicit = pkg.features
	if explicit then return explicit end
	return features.enabledFlags(features.of(pkg), nil)
end

--- The slice of a lockfile entry the bundler needs to resolve a dependency's
--- excludes: the flags the dependency entry named, and the module paths that
--- resolved to. An alias rather than a class so that both a real
--- `lde.Lockfile.Dependency` and a hand-built `{ exclude = {...} }` (tests,
--- callers that only care about features) satisfy it.
---@alias lde.Package.FeatureLockEntry
--- | { features: string[]?, exclude: string[]? }
--- | lde.Lockfile.Dependency

--- The excluded module paths to apply to `target/<alias>`, where `alias` is a
--- dependency of the package being bundled. Two sources, in order:
---
---   1. The dependency's own manifest, when it is readable next to its module
---      dir (`target/<alias>/../lde.json`). lde symlinks every pure-Lua
---      dependency to its source tree, so this is the live manifest and cannot
---      go stale when the dependency edits its own features.
---   2. The locked list, recorded at resolve time. That is what covers
---      dependencies materialized as a copy (anything with a build.lua), whose
---      manifest is not reachable from `target/`.
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

--- Binds `excludesFor` to one package's modules dir, so every scan over
--- `target/` -- the Lua bundle, the native-module bundle, the bloat report --
--- filters entries by the same rules instead of each re-deriving them.
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
