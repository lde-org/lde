const json = require("json")
const ansi = require("ansi")
const fs = require("fs")
local path = require("path")
const semver = require("semver")

const lde = require("lde-core")
const featureFlags = require("lde-core.package.features")
const gitShorthand = require("lde.util.gitShorthand")

--- A manifest's `features.default`, read without failing the add: a dependency
--- with a malformed manifest is a problem the next install reports.
---@param dir string
---@return { name: string?, defaults: string[]? }?
local function readFeatures(dir)
	const raw = fs.read(path.join(dir, "lde.json"))
	if not raw then return nil end
	local ok, config = pcall(json.decode, raw)
	if not ok or type(config) ~= "table" then return nil end
	---@cast config table<string, any>
	local okParse, _, defaults = pcall(featureFlags.parse, config.features, config.name)
	if not okParse then return { name = config.name } end
	return { name = config.name, defaults = defaults }
end

--- The default flags of the named package at `dir`, which may be a monorepo
--- root. Resolution never applies defaults to a dependency by itself, so the
--- only source is the manifest read here.
---@param dir string?
---@param name string
local function defaultsOf(dir, name)
	if not dir or not fs.isdir(dir) then return nil end
	const direct = readFeatures(dir)
	if direct and (direct.name == name or direct.name == nil) then return direct.defaults end

	const pkg = lde.global.findNamedPackageIn(dir, name)
	if pkg then
		const nested = readFeatures(pkg.dir)
		if nested then return nested.defaults end
	end
	return nil
end

--- A local directory a dependency source is readable from without fetching.
---@param value string
---@return string?
local function localSourceDir(value)
	if fs.isdir(value) then return path.normalize(value) end
	return nil
end

--- Materializes a git source into the same cache the installer uses, so the
--- later sync/install is a cache hit. Best-effort: a failed fetch leaves the
--- add intact, just without the dependency's defaults.
---@param repoName string
---@param repoUrl string
---@param branch string?
---@param commit string?
local function fetchGitSource(repoName, repoUrl, branch, commit)
	local ok, repoDir = pcall(lde.global.getOrInitGitRepo, repoName, repoUrl, branch, commit)
	if not ok then return nil end
	return repoDir --[[@as string]]
end

---@param args clap.Args
local function add(args)
	-- Consume flags/options before popping the positional name so their order is free.
	const isDevelopment = args:flag("dev")

	const gitUrl = args:option("git")
	const pathValue = args:option("path")

	const rawName = args:pop()
	if not rawName then
		lde.error.raise("Usage: lde add <name>[@<version>] --path <path> | --git <url>")
	end ---@cast rawName -nil

	local name, versionFromName = rawName:match("^([^@]+)@(.+)$")
	if not name then name = rawName end ---@cast name string

	-- A namespaced package is ns/foo, so only the rocks: prefix is stripped; "ns:foo" must fail validation.
	name = name:match("^rocks:(.+)$") or name

	---@type ("git" | "path")?, string?
	local depType, depValue

	if gitUrl then
		depType = "git"
		depValue = gitUrl
	elseif pathValue then
		depType = "path"
		depValue = pathValue
	else
		-- Dep key is the sub-package name (or repo basename), what lde expects to find inside the repo.
		const shorthandUrl, subPackage, serr = gitShorthand.expand(rawName)
		if serr then
			lde.error.raise(serr)
		end
		if shorthandUrl then
			depType = "git"
			depValue = shorthandUrl
			name = subPackage or lde.global.repoNameFromUrl(shorthandUrl)
		end
	end

	const registryVersion = args:option("version") or versionFromName

	local p, err = lde.Package.open()
	if not p then
		lde.error.raise(err)
	end ---@cast p -nil

	local configPath = p:getConfigPath()

	const configRaw = fs.read(configPath)
	if not configRaw then
		lde.error.raise("Config file not found: " .. configPath)
	end ---@cast configRaw -nil

	local config, derr = lde.util.decodeJson(configRaw)
	if not config then
		lde.error.raise("Failed to parse " .. configPath .. ": " .. derr)
	end ---@cast config lde.Package.Config

	local dependencyTable ---@type lde.Package.Config.Dependencies
	if isDevelopment then
		if not config.devDependencies then
			json.addField(config --[[@as table]], "devDependencies", {})
		end

		dependencyTable = config.devDependencies --[[@as table]]
	else
		if not config.dependencies then
			json.addField(config --[[@as table]], "dependencies", {})
		end
		dependencyTable = config.dependencies --[[@as table]]
	end ---@cast dependencyTable -nil

	-- Existing deps re-pin through their existing kind, so semver@1.0.0 works on a luarocks dep.
	local isRocks = rawName:match("^rocks:") ~= nil
	local isUpdate = false

	const existing = dependencyTable[name]
	if existing then
		if not registryVersion and not depType then
			ansi.warning("Dependency already exists: %s", name)
			return
		end

		-- An explicit spec replaces the existing entry.
		isUpdate = true
		if not depType and existing.luarocks then
			isRocks = true
		elseif not depType and (existing.git or existing.path) then
			lde.error.raise("Cannot set a version on '" .. name .. "': it is a " .. (existing.git ? "git" : "path") .. " dependency", {
				hint = "Use `lde add " .. name .. " --" .. (existing.git ? "git" : "path") .. " <value>` to change its source.",
			})
		end
	end

	local dep
	---@type string?
	local depSourceDir
	---@type lde.Lockfile.GitDependency?
	local gitLockEntry
	local verb = isUpdate ? "Updated" : "Added"
	if depType == "path" then
		dep = { path = depValue }
		depSourceDir = path.resolve(p.dir, path.normalize(depValue --[[@as string]]))
	elseif depType == "git" then
		---@cast depValue -nil
		local branch = args:option("branch")
		local commit = args:option("commit")

		-- Resolve the ref now so a typo'd/dead URL fails at add time; --commit skips resolution.
		local pin = commit
		if not pin then
			const sha, rerr = lde.global.resolveGitRef(depValue, branch)
			if not sha then
				lde.error.raise(
					"Failed to resolve '" .. (branch or "HEAD") .. "' for " .. depValue .. ": " .. (rerr or "unknown error"),
					{ hint = "Double-check the repository URL. It may not exist or may require authentication." })
			end
			pin = sha
		end ---@cast pin -nil

		const lockEntry = { git = depValue, commit = pin }
		if branch then lockEntry.branch = branch end
		gitLockEntry = lockEntry

		dep = { git = depValue, branch = branch, commit = commit }
		if commit then
			-- --commit is an explicit offline pin: never reach the network for it.
			depSourceDir = localSourceDir(depValue)
		else
			depSourceDir = fetchGitSource(name, depValue, branch, pin) or localSourceDir(depValue)
		end
	elseif isRocks then
		local rocksPkg, _, err = lde.util.openLuarocksPackage(name, registryVersion)
		if err then
			lde.error.raise(err, { hint = lde.util.suggestPackage(name, true) })
		end
		depSourceDir = rocksPkg?.dir

		-- @latest pins the concrete newest version now; other constraints stored as given.
		local pinnedVersion = registryVersion
		if registryVersion == "latest" then
			pinnedVersion = lde.util.resolveLuarocksBest(name, "latest")
		end

		dep = { luarocks = name, version = pinnedVersion or nil }
		ansi.printf("{green}%s luarocks %s: %s{reset}%s", verb, isDevelopment ? "dev dependency" : "dependency", name,
			pinnedVersion ? ansi.format(" ({cyan}version: %s{reset})", pinnedVersion) : "")
	else
		lde.global.syncRegistry()

		local portfile, err = lde.global.lookupRegistryPackage(name)
		if not portfile then
			lde.error.raise(err, { hint = lde.util.suggestPackage(name, false) })
		end ---@cast portfile -nil

		-- "latest" means "newest", so a bare name and @latest resolve the same here.
		local resolvedVersion, resolvedCommit, registryGit, registryBranch, registryArchive, registrySha256 =
			lde.global.resolveRegistryVersion(portfile, registryVersion)

		-- Read the manifest from the source install would use, and leave it in the
		-- cache so the later sync/install does not fetch it again. Fall back to a
		-- local source when the fetch fails (offline fake registries).
		if registryArchive then
			local ok, archiveDir, sourceDir = pcall(
				lde.global.getOrInitArchive, registryArchive, nil, nil, registrySha256)
			if ok then depSourceDir = sourceDir or archiveDir end
		elseif registryGit then
			depSourceDir = fetchGitSource(name, registryGit --[[@as string]], registryBranch --[[@as string?]],
				resolvedCommit --[[@as string?]])
		end
		if not depSourceDir and registryGit then
			depSourceDir = localSourceDir(registryGit --[[@as string]])
		end

		-- A single version is saved as a caret range so later installs move to compatible releases.
		local storedVersion = "^" .. resolvedVersion
		if registryVersion and registryVersion ~= "latest" and not semver.isExact(registryVersion) then
			storedVersion = registryVersion
		end

		dep = { version = storedVersion }
		ansi.printf("{green}%s %s: %s{reset} ({cyan}version: %s{reset})", verb, isDevelopment and "dev dependency" or "dependency", name, storedVersion)
	end

	if depType then
		ansi.printf("{green}%s %s: %s{reset} ({cyan}%s: %s{reset})", verb, isDevelopment and "dev dependency" or "dependency", name, depType, depValue)
	end

	-- Explicit features on an existing entry are the user's choice and survive a
	-- re-pin. Otherwise pre-fill the dependency's own `default` list. Resolution
	-- never applies defaults, so without this the entry gets nothing.
	local featuresToWrite = existing?.features
	if not featuresToWrite then
		featuresToWrite = defaultsOf(depSourceDir, name)
	end
	if featuresToWrite then
		(dep --[[@as lde.Package.Config.Dependency]]).features = featuresToWrite
	end

	-- removeField first: addField appends to the encoder's key store, so re-adding would duplicate.
	if isUpdate then
		json.removeField(dependencyTable, name)
	end
	json.addField(dependencyTable, name, dep)

	fs.write(configPath, json.encode(config))

	local lockfile = p:readLockfile()
	if not lockfile then
		lockfile = lde.Lockfile.new(p:getLockfilePath(), {})
	end
	lockfile.raw.dependencies = lockfile.raw.dependencies or {}
	json.removeField(lockfile.raw.dependencies, name)
	if gitLockEntry then
		json.addField(lockfile.raw.dependencies, name, gitLockEntry)
	end
	-- Hash the canonical view install compares against: `package` aliases are
	-- normalized to `name` on read, so the raw decoded table would differ.
	lockfile:setManifestHash(lde.Lockfile.manifestHash(p:reloadConfig()))
	lockfile:save()

	fs.delete(path.join(p:getModulesDir(), ".installed"))
end

return add
