---@alias lpm.Config.Dependencies table<string, lpm.Config.Dependency>

---@class lpm.Config
---@field name string
---@field version string
---@field bin string?
---@field engine string?
---@field scripts table<string, string>?
---@field dependencies lpm.Config.Dependencies?
---@field devDependencies lpm.Config.Dependencies?
local Config = {}
Config.__index = Config

---@param conf lpm.Config
function Config.new(conf)
	return setmetatable(conf, Config) --[[@as lpm.Config]]
end

---@class lpm.Config.GitDependency
---@field git string
---@field commit string?
---@field branch string?
---@field package string? # The actual package name in the repo (used when aliasing)

---@class lpm.Config.PathDependency
---@field path string
---@field package string? # The actual package name at the path (used when aliasing)

---@alias lpm.Config.Dependency
--- | lpm.Config.GitDependency
--- | lpm.Config.PathDependency

return Config
