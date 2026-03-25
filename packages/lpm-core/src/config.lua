---@alias lpm.Config.Dependencies table<string, lpm.Config.Dependency>

---@class lpm.Config
---@field name string
---@field version string
---@field description string?
---@field authors string[]?
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

---@class lpm.Config.BaseDependency
---@field name string? # The actual package name in the registry, when aliasing

---@class lpm.Config.GitDependency: lpm.Config.BaseDependency
---@field git string
---@field commit string?
---@field branch string?

---@class lpm.Config.PathDependency: lpm.Config.BaseDependency
---@field path string

---@class lpm.Config.RegistryDependency: lpm.Config.BaseDependency
---@field version string # Pinned version from the lpm registry

---@alias lpm.Config.Dependency
--- | lpm.Config.GitDependency
--- | lpm.Config.PathDependency
--- | lpm.Config.RegistryDependency

return Config
