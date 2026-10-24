--- lde's package registry client: a git repo whose `packages/<name>.json`
--- portfiles map versions to commits. Dependencies are injected so tests can fake them.

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
---@field stat? fun(p: string): { modifyTime: number }?

---@class lde.RegistryPath
---@field join fun(...: string): string
---@field dirname fun(p: string): string
---@field separator string

---@class lde.RegistrySemver
---@field compare fun(a: string, b: string): number
---@field isExact fun(constraint: string): boolean
---@field maxSatisfying fun(versions: table<string, any>?, constraint: string): string?

---@class lde.RegistryGit
---@field clone fun(url: string, dir: string): any?, string?
---@field open fun(dir: string): any?

---@class lde.RegistryOpts
---@field dirFn fun(): string # registry checkout directory (required: the owner supplies its tree layout)
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
const Registry = {}
Registry.__index = Registry

--- Returns nil + message instead of raising, and rejects non-object documents.
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

---@param opts lde.RegistryOpts
function Registry.new(opts)
	const self = setmetatable({}, Registry)
	self.fs = opts.fs or (require("fs") --[[@as lde.RegistryFs]])
	self.path = opts.path or (require("path") --[[@as lde.RegistryPath]])
	self.semver = opts.semver or (require("semver") --[[@as lde.RegistrySemver]])
	self.git = opts.git
	self.decodeJson = opts.decodeJson or defaultDecodeJson
	self.raise = opts.raise or function(message) error(message, 0) end
	self.dirFn = assert(opts.dirFn, "Registry.new requires dirFn")
	self.url = opts.url or "https://github.com/lde-org/registry"
	return self
end

---@return string
function Registry:getDir()
	return self.dirFn()
end

--- Every command is a fresh process and search/add/install all sync, hence the TTL.
---@type integer
const SYNC_TTL = 10 * 60

--- A failed pull (e.g. offline) is non-fatal; cached data is used.
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
		-- FETCH_HEAD is touched by every fetch; fs.stat may be absent on test doubles.
		const fetchHead = self.path.join(registryDir, ".git", "FETCH_HEAD")
		const fstat = self.fs.stat and self.fs.stat(fetchHead)
		if not (fstat and (os.time() - fstat.modifyTime) < SYNC_TTL) then
			local repo = git.open(registryDir)
			if repo and repo.pull then repo:pull() end
		end
	end
end

--- Mirrors schemas/registry.schema.json in the lde-org/registry repo.
---@param name string
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

---@param name string
---@return lde.Portfile?
---@return string? err
function Registry:lookup(name)
	const nameErr = self:validateName(name)
	if nameErr then
		return nil, "Invalid package name '" .. tostring(name) .. "': " .. nameErr
	end

	-- Namespaced names live at packages/ns/foo.json; re-join on the OS separator for Windows.
	const relPath = (name:gsub("/", self.path.separator))
	const portfilePath = self.path.join(self:getDir(), "packages", relPath .. ".json")
	const content = self.fs.read(portfilePath)
	if not content then
		return nil, "Package '" .. name .. "' not found in lde registry"
	end

	local portfile, perr = self.decodeJson(content)
	if not portfile then
		return nil, "Invalid portfile for '" .. name .. "': " .. perr
	end
	return portfile, nil
end

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
		const commit = versions[version]
		if commit then return version, commit end

		-- A pin that looks exact never resolves elsewhere, so only ranges pick a nearby release.
		if not self.semver.isExact(version) then
			local best = self.semver.maxSatisfying(versions, version)
			if best then return best, versions[best] end
			self.raise("No version of '" .. portfile.name .. "' satisfies: " .. version)
		end

		self.raise("Version '" .. version .. "' of '" .. portfile.name .. "' not found in lde registry")
	end

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
