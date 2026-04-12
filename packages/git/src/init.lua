local git2 = require("git2-sys")

local git = {}

---@param url string
---@param dir string
---@param branch string?
---@param commit string?
function git.clone(url, dir, branch, commit)
	local ok, err = pcall(function()
		local repo = git2.clone(url, dir, branch)
		repo:updateSubmodules()
		if commit then
			repo:checkout(commit)
		end
		repo:free()
	end)
	if not ok then
		return nil, err
	end
	return true
end

---@param cwd string?
---@param ref "HEAD" | string?
function git.getCommitHash(cwd, ref)
	local ok, result = pcall(function()
		local repo = git2.open(cwd or ".")
		local sha = repo:revparse(ref or "HEAD")
		repo:free()
		return sha
	end)
	if not ok then
		return nil, result
	end
	return true, result
end

---@param repoDir string?
function git.pull(repoDir)
	local ok, err = pcall(function()
		local repo = git2.open(repoDir or ".")
		repo:pull()
		repo:free()
	end)
	return ok, ok and nil or err
end

---@param dir string?
---@param bare boolean?
function git.init(dir, bare)
	local ok, err = pcall(function()
		local repo = git2.init(dir or ".", bare)
		repo:free()
	end)
	return ok, ok and nil or err
end

---@param commit string
---@param repoDir string?
function git.checkout(commit, repoDir)
	local ok, err = pcall(function()
		local repo = git2.open(repoDir or ".")
		repo:checkout(commit)
		repo:free()
	end)
	return ok, ok and nil or err
end

function git.version()
	local ok, v = pcall(git2.version)
	return ok, ok and ("libgit2 " .. v) or v
end

---@param dir string?
function git.isInsideWorkTree(dir)
	local ok, repo = pcall(git2.open, dir or ".")
	if not ok then
		return false
	end
	local wd = repo:workdir()
	repo:free()
	return wd ~= nil
end

---@param remoteName string
---@param cwd string?
function git.remoteGetUrl(remoteName, cwd)
	local ok, result = pcall(function()
		local repo = git2.open(cwd or ".")
		local url = repo:remoteUrl(remoteName)
		repo:free()
		return url
	end)
	if not ok then
		return nil, result
	end
	return true, result
end

---@param cwd string?
function git.getCurrentBranch(cwd)
	local ok, result = pcall(function()
		local repo = git2.open(cwd or ".")
		local branch = repo:currentBranch()
		repo:free()
		return branch
	end)
	if not ok then
		return nil, result
	end
	return true, result
end

return git
