--- lde's package registry client. The registry is a git repo whose
--- `packages/<name>.json` files ("portfiles") map package versions to git
--- commits:
---
---   { "name": "foo", "git": "https://...", "versions": { "1.0.0": "<sha>" } }
---
--- A Registry instance is a plain object; every dependency (filesystem, git,
--- json, semver, error raising) is injected through the constructor so
--- callers and tests can substitute fakes — the CLI wires a production
--- instance in lde.global.

---@class lde.Portfile
---@field name string
---@field git string
---@field versions table<string, string>? # version -> commit hash
---@field branch string?
---@field description string?
---@field license string?
---@field authors string[]?
---@field dependencies table<string, string>?

---@class lde.RegistryFs
---@field read fun(p: string): string?
---@field exists fun(p: string): boolean

---@class lde.RegistryPath
---@field join fun(...: string): string
---@field dirname fun(p: string): string
---@field separator string

---@class lde.RegistrySemver
---@field compare fun(a: string, b: string): number

---@class lde.RegistryGit
---@field clone fun(url: string, dir: string): any?, string?
---@field open fun(dir: string): any?

---@class lde.RegistryOpts
---@field dirFn? fun(): string
---@field url? string
---@field fs? lde.RegistryFs
---@field path? lde.RegistryPath
---@field semver? lde.RegistrySemver
---@field git? (fun(): lde.RegistryGit) # lazy git2-sys wrapper; nil when the registry can't sync
---@field decodeJson? (fun(content: string): table?, string?) # safe JSON decode
---@field raise? fun(message: string)

---@class lde.Registry
---@field fs lde.RegistryFs
---@field path lde.RegistryPath
---@field semver lde.RegistrySemver
---@field git (fun(): lde.RegistryGit)? # lazy git2-sys wrapper; nil when the registry can't sync
---@field decodeJson (fun(content: string): table?, string?)? # safe JSON decode
---@field raise fun(message: string) # error raiser; production wires lde.error.raise
---@field dirFn fun(): string # registry checkout directory (dynamic: honors --tree)
---@field url string # registry git URL
---@field isSynced boolean? # only sync once per process
local Registry = {}
Registry.__index = Registry

--- Default registry checkout dir: ~/.lde/registry.
---@return string
local function defaultDir()
	local path = require("path")
	return path.join(os.getenv("HOME") or os.getenv("USERPROFILE"), ".lde", "registry")
end

--- Safe JSON decode: returns nil + message instead of raising on malformed
--- input and rejects non-object documents.
---@param content string
---@return table?, string?
local function defaultDecodeJson(content)
	local json = require("json")
	local ok, decoded = pcall(json.decode, content)
	if not ok then
		return nil, "invalid JSON: " .. tostring(decoded)
	end
	if type(decoded) ~= "table" then
		return nil, "expected a JSON object"
	end
	return decoded, nil
end

---@param opts? lde.RegistryOpts
---@return lde.Registry
function Registry.new(opts)
	opts = opts or {}
	local self = setmetatable({}, Registry)
	self.fs = opts.fs or (require("fs") --[[@as lde.RegistryFs]])
	self.path = opts.path or (require("path") --[[@as lde.RegistryPath]])
	self.semver = opts.semver or (require("semver") --[[@as lde.RegistrySemver]])
	self.git = opts.git
	self.decodeJson = opts.decodeJson or defaultDecodeJson
	self.raise = opts.raise or function(message) error(message, 0) end
	self.dirFn = opts.dirFn or defaultDir
	self.url = opts.url or "https://github.com/lde-org/registry"
	return self
end

--- The registry checkout directory.
---@return string
function Registry:getDir()
	return self.dirFn()
end

--- Clone the registry if not present, otherwise pull to update. A failed pull
--- (e.g. offline) is non-fatal; cached data is used. Only runs once per
--- Registry instance.
function Registry:sync()
	if self.isSynced then return end
	self.isSynced = true

	if not self.git then return end
	local git = self.git()
	if not git then return end

	local registryDir = self:getDir()
	if not self.fs.exists(registryDir) then
		local repo, err = git.clone(self.url, registryDir)
		if not repo then
			self.raise("Failed to clone lde registry: " .. (err or "unknown error"))
		end
		if repo.updateSubmodules then repo:updateSubmodules() end
	else
		local repo = git.open(registryDir)
		if repo and repo.pull then repo:pull() end
	end
end

--- Validates a package name against the lde registry naming rules (mirrors
--- schemas/registry.schema.json in the lde-org/registry repo):
---
---   * flat ("foo") or exactly one namespace level ("ns/foo")
---   * lowercase only; parts use a-z, 0-9, _ and - (no dots, no "..")
---   * each part starts with a letter and ends with a letter or digit
---   * the namespace part is at least 3 characters
---   * the full name is at most 128 characters
---
---@param name string
---@return string? err # nil when the name is valid
function Registry:validateName(name)
	if type(name) ~= "string" or name == "" then
		return "package name cannot be empty"
	end
	if #name > 128 then
		return "package name '" .. name .. "' is too long (max 128 characters)"
	end
	if name:find("..", 1, true) then
		return "package name '" .. name .. "' is invalid: must not contain '..'"
	end
	if name:sub(1, 1) == "/" or name:sub(-1) == "/" then
		return "package name '" .. name .. "' is invalid: must not start or end with '/'"
	end

	local ns, pkg = name:match("^([^/]+)/([^/]+)$")
	if not ns then
		pkg = name
		if name:find("/", 1, true) then
			return "package name '" .. name .. "' is invalid: a namespace is exactly one level deep (e.g. ns/foo)"
		end
	end

	---@param part string
	---@return boolean
	local function isPartValid(part)
		return part:match("^[a-z][a-z0-9_-]*[a-z0-9]$") ~= nil
			or part:match("^[a-z]$") ~= nil
	end

	if not isPartValid(pkg) then
		return "package name '" .. name .. "' is invalid: it must be lowercase, start with a letter, end with a letter or digit, and contain only a-z, 0-9, _ and -"
	end
	if ns then
		if #ns < 3 then
			return "namespace '" .. ns .. "' must be at least 3 characters"
		end
		if not isPartValid(ns) then
			return "namespace '" .. ns .. "' is invalid: it must be lowercase, start with a letter, end with a letter or digit, and contain only a-z, 0-9, _ and -"
		end
	end
	return nil
end

--- Reads a package's portfile from the registry checkout.
---@param name string
---@return lde.Portfile?
---@return string? err
function Registry:lookup(name)
	local nameErr = self:validateName(name)
	if nameErr then
		return nil, "Invalid package name '" .. tostring(name) .. "': " .. nameErr
	end

	-- Namespaced names (ns/foo) live at packages/ns/foo.json; split on "/" and
	-- re-join with the OS separator so nested lookups work on Windows too.
	local relPath = (name:gsub("/", self.path.separator))
	local portfilePath = self.path.join(self:getDir(), "packages", relPath .. ".json")
	local content = self.fs.read(portfilePath)
	if not content then
		return nil, "Package '" .. name .. "' not found in lde registry"
	end

	local portfile, perr = self.decodeJson(content)
	if not portfile then
		return nil, "Invalid portfile for '" .. name .. "': " .. perr
	end
	return portfile, nil
end

--- Resolves a version string (or nil for latest) to a commit hash.
---@param portfile lde.Portfile
---@param version string? # nil or "latest" means the newest version
---@return string version
---@return string commit
function Registry:resolveVersion(portfile, version)
	if version == "latest" then version = nil end
	local versions = portfile.versions
	if not versions then
		self.raise("Package '" .. portfile.name .. "' has no versions in registry")
	end ---@cast versions -nil

	if version then
		local commit = versions[version]
		if not commit then
			self.raise("Version '" .. version .. "' of '" .. portfile.name .. "' not found in lde registry")
		end
		return version, commit
	end

	-- Find highest semver
	local latest = nil
	for v in pairs(versions) do
		if latest == nil or self.semver.compare(v, latest) > 0 then
			latest = v
		end
	end

	if not latest then
		self.raise("No versions available for package '" .. portfile.name .. "'")
	end

	return latest, versions[latest]
end

return Registry
