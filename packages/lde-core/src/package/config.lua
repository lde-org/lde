---@alias lde.Package.Config.Dependencies table<string, lde.Package.Config.Dependency>

---@class lde.Package.Config
---@field name string
---@field version string
---@field description string?
---@field authors string[]?
---@field bin string?
---@field engine string?
---@field scripts table<string, string>?
---@field dependencies lde.Package.Config.Dependencies?
---@field devDependencies lde.Package.Config.Dependencies?
---@field features table<lde.Package.Config.FeatureFlag, string[]>?
local Config = {}
Config.__index = Config

---@param conf lde.Package.Config
function Config.new(conf)
	return setmetatable(conf, Config) --[[@as lde.Package.Config]]
end

---@alias lde.Package.Config.FeatureFlag "windows" | "linux" | "macos" | string

---@class lde.Package.Config.BaseDependency
---@field name string? # The actual package name in the registry, when aliasing
---@field rockspec string? # Path to the rockspec file, relative to the dependency directory
---@field features lde.Package.Config.FeatureFlag[]? # Feature flags to enable for this dependency
---@field optional boolean? # If true, the dependency is not required for the project to run

---@class lde.Package.Config.GitDependency: lde.Package.Config.BaseDependency
---@field git string
---@field commit string?
---@field branch string?

---@class lde.Package.Config.PathDependency: lde.Package.Config.BaseDependency
---@field path string

---@class lde.Package.Config.RegistryDependency: lde.Package.Config.BaseDependency
---@field version string # Pinned version from the lde registry

---@class lde.Package.Config.LuarocksDependency: lde.Package.Config.BaseDependency
---@field luarocks string # Package name on luarocks.org
---@field version string? # Optional version constraint e.g. ">= 1.0"

---@class lde.Package.Config.ArchiveDependency: lde.Package.Config.BaseDependency
---@field archive string # URL to a .zip, .tar.gz, .tar.bz2, etc.

---@alias lde.Package.Config.Dependency
--- | lde.Package.Config.GitDependency
--- | lde.Package.Config.PathDependency
--- | lde.Package.Config.RegistryDependency
--- | lde.Package.Config.LuarocksDependency
--- | lde.Package.Config.ArchiveDependency

return Config
