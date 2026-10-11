const fs = require("fs")
const json = require("json")

---@class lde.global.Config
---@field registry string # Registry URL
const Config = {}
Config.__index = Config

---@param conf lde.global.Config
function Config.new(conf)
	return setmetatable(conf, Config) --[[@as lde.global.Config]]
end

---@type lde.global.Config?
local cache = nil

const defaults = Config.new({
	registry = "https://github.com/lde-org/registry"
})

const global = require("lde-core.global")

---@return lde.global.Config
local function getConfig()
	if cache then return cache end

	const configPath = global.getConfigPath()

	if not fs.exists(configPath) then
		cache = defaults
		return cache
	end

	const content = fs.read(configPath)
	const ok, data = pcall(json.decode, content or "")
	if not ok or type(data) ~= "table" then
		cache = defaults
		return cache
	end

	cache = Config.new({
		registry = type(data.registry) == "string" ? data.registry : defaults.registry
	})

	return cache
end

return getConfig
