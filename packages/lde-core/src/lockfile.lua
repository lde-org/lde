local fs = require("fs")
local json = require("json")
local util = require("util")

local lde = require("lde-core")

---@class lde.Lockfile.BaseDependency
---@field name string?
---@field rockspec string? # URL or relative path to the rockspec file
---@field optional boolean? # If true, only installed when enabled via features
---@field features lde.Package.Config.FeatureFlag[]? # Feature flags to enable for this dependency

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
---@field manifestHash string? # hash of lde.json's dependency declarations; a mismatch means the pins are stale
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
		lde.error.raise("Unsupported lockfile version: " .. tostring(self.raw.version))
	end
end

--- Deterministic hash of the manifest's dependency declarations. Any change to
--- `dependencies`, `devDependencies`, or `features` changes the hash, which
--- invalidates the lockfile's pins (see `Lockfile:isStale`). `json.encode`
--- sorts the keys of tables it hasn't decoded itself, so the hash is stable
--- regardless of key order in the manifest file.
---@param config lde.Package.Config
---@return string
function Lockfile.manifestHash(config)
	return util.fnv1a(json.encode({
		dependencies = config.dependencies or {},
		devDependencies = config.devDependencies or {},
		features = config.features or {},
	}))
end

---@return string?
function Lockfile:getManifestHash()
	return self.raw.manifestHash
end

---@param hash string
function Lockfile:setManifestHash(hash)
	self.raw.manifestHash = hash
end

--- True when the manifest's dependency declarations no longer match the
--- declarations the lockfile was resolved from. A stale lockfile must not pin
--- resolution — e.g. a dep switched from git to registry in lde.json would
--- otherwise keep installing the old git source (or conflict with the new
--- registry requests). Lockfiles written before the hash existed count as
--- stale so they re-resolve exactly once and are rewritten with a hash.
---@param config lde.Package.Config
---@return boolean
function Lockfile:isStale(config)
	return self.raw.manifestHash ~= Lockfile.manifestHash(config)
end

---@param name string
---@return lde.Lockfile.Dependency?
function Lockfile:getDependency(name)
	return self:getDependencies()[name]
end

return Lockfile
