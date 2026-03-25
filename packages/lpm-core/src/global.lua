local global = {}

local fs = require("fs")
local git = require("git")
local json = require("json")
local path = require("path")
local semver = require("semver")

local REGISTRY_URL = "https://github.com/codebycruz/lpm-registry"

global.currentVersion = "0.7.2"

---@param s string
local function sanitize(s)
	return (string.gsub(s, "[^%w_%-]", "_"))
end

function global.getDir()
	local home = os.getenv("HOME") or os.getenv("USERPROFILE")
	return path.join(home, ".lpm")
end

function global.getGitCacheDir()
	return path.join(global.getDir(), "git")
end

function global.getToolsDir()
	return path.join(global.getDir(), "tools")
end

function global.getRegistryDir()
	return path.join(global.getDir(), "registry")
end

-- Only sync once per process invocation
local registrySynced = false

--- Clones the registry if not present, otherwise pulls to update.
--- A failed pull (e.g. offline) is non-fatal; cached data is used.
function global.syncRegistry()
	if registrySynced then return end
	registrySynced = true

	local registryDir = global.getRegistryDir()
	if not fs.exists(registryDir) then
		local ok, err = git.clone(REGISTRY_URL, registryDir)
		if not ok then
			error("Failed to clone lpm registry: " .. (err or "unknown error"))
		end
	else
		git.pull(registryDir)
	end
end

---@param name string
---@return table? portfile
---@return string? err
function global.lookupRegistryPackage(name)
	local portfilePath = path.join(global.getRegistryDir(), "packages", name .. ".json")
	local content = fs.read(portfilePath)
	if not content then
		return nil, "Package '" .. name .. "' not found in registry"
	end
	return json.decode(content), nil
end

--- Resolves a version string (or nil for latest) to a commit hash.
---@param portfile table
---@param version string? # nil means latest
---@return string version
---@return string commit
function global.resolveRegistryVersion(portfile, version)
	local versions = portfile.versions
	if not versions then
		error("Package '" .. portfile.name .. "' has no versions in registry")
	end

	if version then
		local commit = versions[version]
		if not commit then
			error("Version '" .. version .. "' of '" .. portfile.name .. "' not found in registry")
		end
		return version, commit
	end

	-- Find highest semver
	local latest = nil
	for v in pairs(versions) do
		if latest == nil or semver.compare(v, latest) > 0 then
			latest = v
		end
	end

	if not latest then
		error("No versions available for package '" .. portfile.name .. "'")
	end

	return latest, versions[latest]
end

--- Builds the cache directory name for a git repo.
--- Format: name, name-branch, or name-branch-commit
---@param repoName string
---@param branch string?
---@param commit string?
---@return string
function global.getGitRepoDir(repoName, branch, commit)
	local parts = { sanitize(repoName) }

	if branch then
		parts[#parts + 1] = sanitize(branch)
	end

	if commit then
		parts[#parts + 1] = sanitize(commit)
	end

	local fullName = table.concat(parts, "-")
	return path.join(global.getGitCacheDir(), fullName)
end

---@param repoName string
---@param repoUrl string
---@param branch string?
---@param commit string?
function global.cloneDir(repoName, repoUrl, branch, commit)
	local repoDir = global.getGitRepoDir(repoName, branch, commit)
	return git.clone(repoUrl, repoDir, branch, commit)
end

---@param repoName string
---@param repoUrl string
---@param branch string?
---@param commit string?
function global.getOrInitGitRepo(repoName, repoUrl, branch, commit)
	local repoDir = global.getGitRepoDir(repoName, branch, commit)
	if not fs.exists(repoDir) then
		local ok, err = global.cloneDir(repoName, repoUrl, branch, commit)
		if not ok then
			error("Failed to clone git repository: " .. err)
		end
	end

	return repoDir
end

function global.init()
	local dir = global.getDir()
	if not fs.exists(dir) then
		fs.mkdir(dir)
	end

	local gitCacheDir = global.getGitCacheDir()
	if not fs.exists(gitCacheDir) then
		fs.mkdir(gitCacheDir)
	end

	local toolsDir = global.getToolsDir()
	if not fs.exists(toolsDir) then
		fs.mkdir(toolsDir)
	end
end

return global
