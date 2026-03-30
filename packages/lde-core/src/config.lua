---@alias lde.Config.Dependencies table<string, lde.Config.Dependency>

---@class lde.Config
---@field name string
---@field version string
---@field description string?
---@field authors string[]?
---@field bin string?
---@field engine string?
---@field scripts table<string, string>?
---@field dependencies lde.Config.Dependencies?
---@field devDependencies lde.Config.Dependencies?
---@field features table<string, string[]>?
local Config = {}
Config.__index = Config

---@param conf lde.Config
function Config.new(conf)
	return setmetatable(conf, Config) --[[@as lde.Config]]
end

---@alias lde.Config.FeatureFlag "windows" | "linux" | "macos" | string

---@class lde.Config.BaseDependency
---@field name string? # The actual package name in the registry, when aliasing
---@field rockspec string? # Path to the rockspec file, relative to the dependency directory
---@field features lde.Config.FeatureFlag[]? # Feature flags to enable for this dependency
---@field optional boolean? # If true, the dependency is not required for the project to run

---@class lde.Config.GitDependency: lde.Config.BaseDependency
---@field git string
---@field commit string?
---@field branch string?

---@class lde.Config.PathDependency: lde.Config.BaseDependency
---@field path string

---@class lde.Config.RegistryDependency: lde.Config.BaseDependency
---@field version string # Pinned version from the lde registry

---@class lde.Config.LuarocksDependency: lde.Config.BaseDependency
---@field luarocks string # Package name on luarocks.org
---@field version string? # Optional version constraint e.g. ">= 1.0"

---@class lde.Config.ArchiveDependency: lde.Config.BaseDependency
---@field archive string # URL to a .zip, .tar.gz, .tar.bz2, etc.

---@alias lde.Config.Dependency
--- | lde.Config.GitDependency
--- | lde.Config.PathDependency
--- | lde.Config.RegistryDependency
--- | lde.Config.LuarocksDependency
--- | lde.Config.ArchiveDependency

return Config
