local json = require("json")
local ansi = require("ansi")
local fs = require("fs")

local Package = require("lpm-core.package")
local global = require("lpm-core.global")

---@param args clap.Args
local function add(args)
	local rawName = assert(args:pop(), "Usage: lpm add <name>[@<version>] --path <path> | --git <url>")
	local isDevelopment = args:flag("dev")

	-- Support lpm add <name>@<version> syntax
	local name, versionFromName = rawName:match("^([^@]+)@(.+)$")
	if not name then name = rawName end

	---@type ("git" | "path")?, string?
	local depType, depValue

	local gitUrl = args:option("git")
	local pathValue = args:option("path")

	if gitUrl then
		depType = "git"
		depValue = gitUrl
	elseif pathValue then
		depType = "path"
		depValue = pathValue
	end

	local registryVersion = args:option("version") or versionFromName

	local p, err = Package.open()
	if not p then
		ansi.printf("{red}%s", err)
		return
	end

	local configPath = p:getConfigPath()

	---@type lpm.Config
	local config = json.decode(fs.read(p:getConfigPath()))

	local dependencyTable ---@type lpm.Config.Dependencies
	if isDevelopment then
		if not config.devDependencies then
			config.devDependencies = {}
		end

		dependencyTable = config.devDependencies
	else
		if not config.dependencies then
			config.dependencies = {}
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
	else
		-- Registry dependency
		global.syncRegistry()

		local portfile, err = global.lookupRegistryPackage(name)
		if not portfile then
			ansi.printf("{red}%s", err)
			return
		end

		local resolvedVersion = global.resolveRegistryVersion(portfile, registryVersion or nil)
		dep = { version = resolvedVersion }
		ansi.printf("{green}Added dependency: %s{reset} ({cyan}version: %s{reset})", name, resolvedVersion)
	end

	if depType then
		ansi.printf("{green}Added dependency: %s{reset} ({cyan}%s: %s{reset})", name, depType, depValue)
	end

	json.addField(dependencyTable, name, dep)

	fs.write(configPath, json.encode(config))
end

return add
