local json = require("json")
local ansi = require("ansi")
local fs = require("fs")
local path = require("path")

local lde = require("lde-core")

---@param args clap.Args
local function remove(args)
	local name = args:pop()
	if not name then
		lde.error.raise("Usage: lde remove <name>")
	end

	local pkg, err = lde.Package.open()
	if not pkg then
		lde.error.raise(err)
	end

	local configPath = pkg:getConfigPath()

	local configRaw = fs.read(configPath)
	if not configRaw then
		lde.error.raise("Failed to read config: " .. configPath)
	end

	local config = json.decode(configRaw)

	-- A dependency may live in either runtime `dependencies` or `devDependencies`;
	-- remove the name from whichever table(s) hold it.
	local inDeps = config.dependencies and config.dependencies[name] ~= nil
	local inDevDeps = config.devDependencies and config.devDependencies[name] ~= nil

	if not inDeps and not inDevDeps then
		ansi.printf("{yellow}Dependency does not exist: %s", name)
		return
	end

	if inDeps then json.removeField(config.dependencies, name) end
	if inDevDeps then json.removeField(config.devDependencies, name) end

	fs.write(configPath, json.encode(config))

	local lockfile = pkg:readLockfile()
	if lockfile then
		json.removeField(lockfile.raw.dependencies, name)
		lockfile:setManifestHash(lde.Lockfile.manifestHash(config))
		lockfile:save()
	end

	fs.delete(path.join(pkg:getModulesDir(), ".installed"))

	if inDeps then
		ansi.printf("{green}Removed dependency: %s", name)
	else
		ansi.printf("{green}Removed dev dependency: %s", name)
	end
end

return remove
