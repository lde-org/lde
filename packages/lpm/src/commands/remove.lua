local json = require("json")
local ansi = require("ansi")
local fs = require("fs")

local lpm = require("lpm-core")

---@param args clap.Args
local function remove(args)
	local name = assert(args:pop(), "Usage: lpm remove <name>")

	local pkg, err = lpm.Package.open()
	if not pkg then
		ansi.printf("{red}%s", err)
		return
	end

	local configPath = pkg:getConfigPath()

	local configRaw = fs.read(configPath)
	if not configRaw then
		ansi.printf("{red}Failed to read config: %s", configPath)
		return
	end

	local config = json.decode(configRaw)
	if not config.dependencies then
		config.dependencies = {}
	end

	if not config.dependencies[name] then
		ansi.printf("{yellow}Dependency does not exist: %s", name)
		return
	end

	json.removeField(config.dependencies, name)

	fs.write(configPath, json.encode(config))

	ansi.printf("{green}Removed dependency: %s", name)
end

return remove
