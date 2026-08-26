local json = require("json")
local ansi = require("ansi")
local fs = require("fs")
local path = require("path")

local lde = require("lde-core")
local gitShorthand = require("lde.util.gitShorthand")

---@param args clap.Args
local function add(args)
	-- Consume flags/options before popping the positional name so
	-- `lde add --dev foo` parses the same as `lde add foo --dev`.
	local isDevelopment = args:flag("dev")

	local gitUrl = args:option("git")
	local pathValue = args:option("path")

	local rawName = args:pop()
	if not rawName then
		lde.error.raise("Usage: lde add <name>[@<version>] --path <path> | --git <url>")
	end ---@cast rawName -nil

	-- Support lde add <name>@<version> syntax
	local name, versionFromName = rawName:match("^([^@]+)@(.+)$")
	if not name then name = rawName end ---@cast name string

	-- Strip only the rocks: prefix (e.g. rocks:foo -> foo). Other prefixes are
	-- not real; a namespaced package is ns/foo, so "ns:foo" must fail
	-- validation below instead of silently becoming "foo".
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
		-- Git shorthand: gh:owner/repo, or gh:<pkg>@owner/repo for a package
		-- inside a monorepo. The dependency key is the sub-package name (or
		-- the repo basename for the plain form) — the name lde expects to find
		-- inside the repo.
		local shorthandUrl, subPackage, serr = gitShorthand.expand(rawName)
		if serr then
			lde.error.raise(serr)
		end
		if shorthandUrl then
			depType = "git"
			depValue = shorthandUrl
			name = subPackage or lde.global.repoNameFromUrl(shorthandUrl)
		end
	end

	local registryVersion = args:option("version") or versionFromName

	local p, err = lde.Package.open()
	if not p then
		lde.error.raise(err)
	end ---@cast p -nil

	local configPath = p:getConfigPath()

	local configRaw = fs.read(configPath)
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
			json.addField(config, "devDependencies", {})
		end

		dependencyTable = config.devDependencies
	else
		if not config.dependencies then
			json.addField(config, "dependencies", {})
		end
		dependencyTable = config.dependencies
	end ---@cast dependencyTable -nil

	-- Whether the name routes through the luarocks branch. Existing deps are
	-- re-pinned through whatever kind they already are, so `lde add
	-- semver@1.0.0` works on a luarocks dep without needing the rocks: prefix.
	local isRocks = rawName:match("^rocks:") ~= nil
	local isUpdate = false

	local existing = dependencyTable[name]
	if existing then
		if not registryVersion and not depType then
			ansi.warning("Dependency already exists: %s", name)
			return
		end

		-- An explicit spec (version, or a --git/--path source) replaces the
		-- existing entry: `lde add semver@1.0.0` upgrades/downgrades the pin.
		isUpdate = true
		if not depType and existing.luarocks then
			isRocks = true
		elseif not depType and (existing.git or existing.path) then
			lde.error.raise("Cannot set a version on '" .. name .. "': it is a " .. (existing.git and "git" or "path") .. " dependency", {
				hint = "Use `lde add " .. name .. " --" .. (existing.git and "git" or "path") .. " <value>` to change its source.",
			})
		end
	end

	local dep
	---@type lde.Lockfile.GitDependency?
	local gitLockEntry
	local verb = isUpdate and "Updated" or "Added"
	if depType == "path" then
		dep = { path = depValue }
	elseif depType == "git" then
		---@cast depValue -nil
		local branch = args:option("branch")
		local commit = args:option("commit")

		-- Resolve the ref now (lsRemote) instead of on the next install, so a
		-- typo'd or dead URL fails at add time and the lockfile gets the
		-- auto-pin immediately. An explicit --commit skips resolution — it is
		-- a deliberate pin (and keeps fully-offline adds working); the install
		-- still verifies the commit exists when it fetches the repo.
		local pin = commit
		if not pin then
			local sha, rerr = lde.global.resolveGitRef(depValue, branch)
			if not sha then
				lde.error.raise(
					"Failed to resolve '" .. (branch or "HEAD") .. "' for " .. depValue .. ": " .. (rerr or "unknown error"),
					{ hint = "Double-check the repository URL. It may not exist or may require authentication." })
			end
			pin = sha
		end ---@cast pin -nil

		local lockEntry = { git = depValue, commit = pin }
		if branch then lockEntry.branch = branch end
		gitLockEntry = lockEntry

		dep = { git = depValue, branch = branch, commit = commit }
	elseif isRocks then
		local _, _, err = lde.util.openLuarocksPackage(name, registryVersion)
		if err then
			lde.error.raise(err, { hint = lde.util.suggestPackage(name, true) })
		end

		-- @latest resolves the newest version now and pins that concrete
		-- version; any other constraint is stored as given (a bare name stays
		-- version-less, so installs keep resolving the newest).
		local pinnedVersion = registryVersion
		if registryVersion == "latest" then
			pinnedVersion = lde.util.resolveLuarocksBest(name, "latest")
		end

		dep = { luarocks = name, version = pinnedVersion or nil }
		ansi.printf("{green}%s luarocks %s: %s{reset}%s", verb, isDevelopment and "dev dependency" or "dependency", name,
			pinnedVersion and ansi.format(" ({cyan}version: %s{reset})", pinnedVersion) or "")
	else
		-- Registry dependency
		lde.global.syncRegistry()

		local portfile, err = lde.global.lookupRegistryPackage(name)
		if not portfile then
			lde.error.raise(err, { hint = lde.util.suggestPackage(name, false) })
		end ---@cast portfile -nil

		-- resolveRegistryVersion treats "latest" as "newest", so @latest pins
		-- the concrete latest version here.
		local resolvedVersion = lde.global.resolveRegistryVersion(portfile, registryVersion)
		dep = { version = resolvedVersion }
		ansi.printf("{green}%s %s: %s{reset} ({cyan}version: %s{reset})", verb, isDevelopment and "dev dependency" or "dependency", name, resolvedVersion)
	end

	if depType then
		ansi.printf("{green}%s %s: %s{reset} ({cyan}%s: %s{reset})", verb, isDevelopment and "dev dependency" or "dependency", name, depType, depValue)
	end

	-- removeField first: addField appends the key to the encoder's key store,
	-- so re-adding an existing key without removing it would emit a duplicate.
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
	lockfile:setManifestHash(lde.Lockfile.manifestHash(config))
	lockfile:save()

	fs.delete(path.join(p:getModulesDir(), ".installed"))
end

return add
