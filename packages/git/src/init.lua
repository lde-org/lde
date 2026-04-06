local process = require("process2")

local git = {}

---@param url string
---@param dir string
---@param branch string?
---@param commit string?
function git.clone(url, dir, branch, commit)
	local args = { "clone", url, dir }

	if branch then
		args[#args + 1] = "-b"
		args[#args + 1] = branch
	end

	local code, stdout, stderr = process.exec("git", args)
	if code ~= 0 then
		return nil, stderr
	end

	if commit then
		return git.checkout(commit, dir)
	end

	return true, stdout
end

---@param cwd string?
---@param ref "HEAD" | string?
function git.getCommitHash(cwd, ref)
	local code, stdout, stderr = process.exec("git", { "rev-parse", ref or "HEAD" }, { cwd = cwd })
	if code ~= 0 then
		return nil, stderr
	end

	return true, string.gsub(stdout, "%s+$", "")
end

---@param repoDir string?
function git.pull(repoDir)
	local code, _, stderr = process.exec("git", { "pull" }, { cwd = repoDir })
	return code == 0, stderr
end

---@param dir string?
---@param bare boolean?
function git.init(dir, bare)
	local args = { "init" }
	if bare then
		args[#args + 1] = "--bare"
	end
	local code, _, stderr = process.exec("git", args, { cwd = dir })
	return code == 0, stderr
end

---@param commit string
---@param repoDir string?
function git.checkout(commit, repoDir)
	local code, _, stderr = process.exec("git", { "checkout", commit }, { cwd = repoDir })
	return code == 0, stderr
end

function git.version()
	local code, stdout, stderr = process.exec("git", { "--version" })
	return code == 0, stdout or stderr
end

---@param dir string?
function git.isInsideWorkTree(dir)
	local code, _, stderr = process.exec("git", { "rev-parse", "--is-inside-work-tree" }, { cwd = dir })
	return code == 0, stderr
end

---@param remoteName string
---@param cwd string?
function git.remoteGetUrl(remoteName, cwd)
	local code, stdout, stderr = process.exec("git", { "remote", "get-url", remoteName }, { cwd = cwd })
	return code == 0, stdout or stderr
end

---@param cwd string?
function git.getCurrentBranch(cwd)
	local code, stdout, stderr = process.exec("git", { "rev-parse", "--abbrev-ref", "HEAD" }, { cwd = cwd })
	return code == 0, stdout or stderr
end

return git
