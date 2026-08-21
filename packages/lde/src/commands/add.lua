local json = require("json")
local ansi = require("ansi")
local fs = require("fs")
local path = require("path")

local lde = require("lde-core")

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

	if dependencyTable[name] then
		ansi.printf("{yellow}Dependency already exists: %s", name)
		return
	end

	local dep
	if depType == "path" then
		dep = { path = depValue }
	elseif depType == "git" then
		local branch = args:option("branch")
		local commit = args:option("commit")

		dep = { git = depValue, branch = branch, commit = commit }
	elseif rawName:match("^rocks:") then
		local _, _, err = lde.util.openLuarocksPackage(name, registryVersion)
		if err then
			lde.error.raise(err)
		end

		-- @latest resolves the newest version now and pins that concrete
		-- version; any other constraint is stored as given (a bare name stays
		-- version-less, so installs keep resolving the newest).
		local pinnedVersion = registryVersion
		if registryVersion == "latest" then
			pinnedVersion = lde.util.resolveLuarocksBest(name, "latest")
		end

		dep = { luarocks = name, version = pinnedVersion or nil }
		ansi.printf("{green}Added luarocks %s: %s{reset}", isDevelopment and "dev dependency" or "dependency", name)
	else
		-- Registry dependency
		lde.global.syncRegistry()

		local portfile, err = lde.global.lookupRegistryPackage(name)
		if not portfile then
			lde.error.raise(err)
		end ---@cast portfile -nil

		-- resolveRegistryVersion treats "latest" as "newest", so @latest pins
		-- the concrete latest version here.
		local resolvedVersion = lde.global.resolveRegistryVersion(portfile, registryVersion)
		dep = { version = resolvedVersion }
		ansi.printf("{green}Added %s: %s{reset} ({cyan}version: %s{reset})", isDevelopment and "dev dependency" or "dependency", name, resolvedVersion)
	end

	if depType then
		ansi.printf("{green}Added %s: %s{reset} ({cyan}%s: %s{reset})", isDevelopment and "dev dependency" or "dependency", name, depType, depValue)
	end

	json.addField(dependencyTable, name, dep)

	fs.write(configPath, json.encode(config))

	local lockfile = p:readLockfile()
	if lockfile then
		lockfile.raw.dependencies = lockfile.raw.dependencies or {}
		json.removeField(lockfile.raw.dependencies, name)
		lockfile:setManifestHash(lde.Lockfile.manifestHash(config))
		lockfile:save()
	end

	fs.delete(path.join(p:getModulesDir(), ".installed"))
end

return add
