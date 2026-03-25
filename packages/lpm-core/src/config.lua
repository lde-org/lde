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
---@field rockspec string? # Path to the rockspec file, relative to the dependency directory

---@class lpm.Config.GitDependency: lpm.Config.BaseDependency
---@field git string
---@field commit string?
---@field branch string?

---@class lpm.Config.PathDependency: lpm.Config.BaseDependency
---@field path string

---@class lpm.Config.RegistryDependency: lpm.Config.BaseDependency
---@field version string # Pinned version from the lpm registry

---@class lpm.Config.LuarocksDependency: lpm.Config.BaseDependency
---@field luarocks string # Package name on luarocks.org
---@field version string? # Optional version constraint e.g. ">= 1.0"

---@class lpm.Config.ArchiveDependency: lpm.Config.BaseDependency
---@field archive string # URL to a .zip, .tar.gz, .tar.bz2, etc.

---@alias lpm.Config.Dependency
--- | lpm.Config.GitDependency
--- | lpm.Config.PathDependency
--- | lpm.Config.RegistryDependency
--- | lpm.Config.LuarocksDependency
--- | lpm.Config.ArchiveDependency

return Config
