local fs = require("fs")
local json = require("json")

---@class lpm.Lockfile.BaseDependency
---@field name string?
---@field rockspec string? # URL or relative path to the rockspec file

---@class lpm.Lockfile.GitDependency: lpm.Lockfile.BaseDependency
---@field git string
---@field commit string # Always resolved to a specific commit hash
---@field branch string?

---@class lpm.Lockfile.PathDependency: lpm.Lockfile.BaseDependency
---@field path string

---@class lpm.Lockfile.ArchiveDependency: lpm.Lockfile.BaseDependency
---@field archive string # URL to the archive

---@alias lpm.Lockfile.Dependency
--- | lpm.Lockfile.GitDependency
--- | lpm.Lockfile.PathDependency
--- | lpm.Lockfile.ArchiveDependency

---@class lpm.Lockfile.Raw
---@field version "1"
---@field dependencies table<string, lpm.Lockfile.Dependency>

---@class lpm.Lockfile
---@field path string
---@field raw lpm.Lockfile.Raw
local Lockfile = {}
Lockfile.__index = Lockfile

---@param p string
---@return lpm.Lockfile?
function Lockfile.open(p)
	local content = fs.read(p)
	if not content then
		return nil
	end

	return setmetatable({ path = p, raw = json.decode(content) }, Lockfile)
end

---@param p string
---@param dependencies table<string, lpm.Lockfile.Dependency>
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
---@return lpm.Lockfile.Dependency?
function Lockfile:getDependency(name)
	return self:getDependencies()[name]
end

return Lockfile
