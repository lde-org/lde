local fs = require("fs")
local json = require("json")

---@class lde.Lockfile.BaseDependency
---@field name string?
---@field rockspec string? # URL or relative path to the rockspec file

---@class lde.Lockfile.GitDependency: lde.Lockfile.BaseDependency
---@field git string
---@field commit string # Always resolved to a specific commit hash
---@field branch string?

---@class lde.Lockfile.PathDependency: lde.Lockfile.BaseDependency
---@field path string

---@class lde.Lockfile.ArchiveDependency: lde.Lockfile.BaseDependency
---@field archive string # URL to the archive

---@alias lde.Lockfile.Dependency
--- | lde.Lockfile.GitDependency
--- | lde.Lockfile.PathDependency
--- | lde.Lockfile.ArchiveDependency

---@class lde.Lockfile.Raw
---@field version "1"
---@field dependencies table<string, lde.Lockfile.Dependency>

---@class lde.Lockfile
---@field path string
---@field raw lde.Lockfile.Raw
local Lockfile = {}
Lockfile.__index = Lockfile

---@param p string
---@return lde.Lockfile?
function Lockfile.open(p)
	local content = fs.read(p)
	if not content then
		return nil
	end

	return setmetatable({ path = p, raw = json.decode(content) }, Lockfile)
end

---@param p string
---@param dependencies table<string, lde.Lockfile.Dependency>
function Lockfile.new(p, dependencies)
	return setmetatable({
		path = p,
		raw = {
			version = "1",
			dependencies = dependencies
		}
	}, Lockfile)
end

function Lockfile:save()
	local content = json.encode(self.raw)
	return fs.write(self.path, content)
end

function Lockfile:getVersion()
	return self.raw.version
end

function Lockfile:getDependencies()
	if self:getVersion() == "1" then
		return self.raw.dependencies
	else
		error("Unsupported lockfile version: " .. tostring(self.raw.version))
	end
end

---@param name string
---@return lde.Lockfile.Dependency?
function Lockfile:getDependency(name)
	return self:getDependencies()[name]
end

return Lockfile
