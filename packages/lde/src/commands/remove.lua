const json = require("json")
const ansi = require("ansi")
const fs = require("fs")
const path = require("path")

const lde = require("lde-core")

---@param args clap.Args
local function remove(args)
	const name = args:pop()
	if not name then
		lde.error.raise("Usage: lde remove <name>")
	end ---@cast name -nil

	const pkg, err = lde.Package.open()
	if not pkg then
		lde.error.raise(err)
	end ---@cast pkg -nil

	local configPath = pkg:getConfigPath()

	const configRaw = fs.read(configPath)
	if not configRaw then
		lde.error.raise("Failed to read config: " .. configPath)
	end ---@cast configRaw -nil

	const config, derr = lde.util.decodeJson(configRaw)
	if not config then
		lde.error.raise("Failed to parse " .. configPath .. ": " .. derr)
	end ---@cast config -nil

	-- The name may be in either dependencies or devDependencies; remove from whichever holds it.
	const inDeps = config.dependencies and config.dependencies[name] ~= nil
	const inDevDeps = config.devDependencies and config.devDependencies[name] ~= nil

	if not inDeps and not inDevDeps then
		ansi.printf("{yellow}Dependency does not exist: %s", name)
		return
	end

	if inDeps then json.removeField(config.dependencies, name) end
	if inDevDeps then json.removeField(config.devDependencies, name) end

	fs.write(configPath, json.encode(config))

	const lockfile = pkg:readLockfile()
	if lockfile then
		lockfile.raw.dependencies = lockfile.raw.dependencies or {}
		json.removeField(lockfile.raw.dependencies, name)
		-- Hash the canonical view install compares against: `package` aliases are
		-- normalized to `name` on read, so the raw decoded table would differ.
		pkg.cachedConfig, pkg.cachedConfigMtime = nil, nil
		lockfile:setManifestHash(lde.Lockfile.manifestHash(pkg:readConfig()))
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
