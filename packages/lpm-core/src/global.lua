local global = {}

local fs = require("fs")
local path = require("path")
local process = require("process")

global.currentVersion = "0.6.3"

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
function global.cloneDir(repoName, repoUrl, branch)
	local repoDir = global.getGitRepoDir(repoName, branch)
	local args = { "clone" }

	if branch then
		args[#args + 1] = "--branch"
		args[#args + 1] = branch
	end

	args[#args + 1] = repoUrl
	args[#args + 1] = repoDir

	return process.spawn("git", args)
end

---@param repoName string
---@param repoUrl string
---@param branch string?
---@param commit string?
function global.getOrInitGitRepo(repoName, repoUrl, branch, commit)
	local repoDir = global.getGitRepoDir(repoName, branch, commit)
	if not fs.exists(repoDir) then
		local ok, err = global.cloneDir(repoName, repoUrl, branch)
		if not ok then
			error("Failed to clone git repository: " .. err)
		end

		if commit then
			local checkoutOk, checkoutErr = process.spawn("git", { "checkout", commit }, { cwd = repoDir })
			if not checkoutOk then
				error("Failed to checkout commit " .. commit .. ": " .. checkoutErr)
			end
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
