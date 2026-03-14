local Package = require("lpm-core.package")

local ansi = require("ansi")
local env = require("env")
local fs = require("fs")
local path = require("path")
local process = require("process")
local global = require("lpm-core.global")

--- Parses a GitHub /tree/<branch> URL into a clone URL and branch.
--- e.g. "https://github.com/user/repo/tree/my-branch" -> "https://github.com/user/repo.git", "my-branch"
--- Regular git URLs are returned as-is with no branch.
---@param url string
---@return string cloneUrl
---@return string? branch
local function parseGitUrl(url)
	local base, branch = url:match("^(https://github%.com/[^/]+/[^/]+)/tree/(.+)$")
	if base and branch then
		return base .. ".git", branch
	end

	return url, nil
end

--- Derives a cache-friendly repo name from a git URL.
---@param url string
---@return string
local function repoNameFromUrl(url)
	return url:match("([^/]+)%.git$") or url:match("([^/]+)$")
end

--- Clones or retrieves a cached git repo directory, with optional branch support.
---@param repoName string
---@param cloneUrl string
---@param branch string?
---@return string repoDir
local function getOrCloneRepo(repoName, cloneUrl, branch)
	local safeName = repoName
	if branch then
		safeName = repoName .. "-" .. branch
	end

	local repoDir = global.getGitRepoDir(safeName)
	if not fs.exists(repoDir) then
		local args = { "clone", cloneUrl, repoDir }
		if branch then
			args = { "clone", "--branch", branch, cloneUrl, repoDir }
		end

		local ok, err = process.spawn("git", args)
		if not ok then
			error("Failed to clone git repository: " .. (err or "unknown error"))
		end
	end

	return repoDir
end

--- Finds a named package inside a repo by scanning for lpm.json files.
---@param dir string
---@param name string
---@return lpm.Package?
---@return string?
local function findNamedPackageIn(dir, name)
	for _, config in ipairs(fs.scan(dir, "**" .. path.separator .. "lpm.json")) do
		local parentDir = path.join(dir, path.dirname(config))
		local pkg = Package.open(parentDir)
		if pkg and pkg:getName() == name then
			return pkg, nil
		end
	end

	return nil, "No package named '" .. name .. "' found in: " .. dir
end

---@param pkg lpm.Package
---@param scriptArgs string[]
---@param cwd string
local function executePackage(pkg, scriptArgs, cwd)
	pkg:build()
	pkg:installDependencies()

	local ok, err = pkg:runFile(nil, scriptArgs, nil, cwd)
	if not ok then
		error("Failed to run script: " .. err)
	end
end

---@param args clap.Args
local function x(args)
	local gitUrl = args:option("git")
	local localPath = args:option("path")
	local userCwd = env.cwd()

	if gitUrl then
		local cloneUrl, branch = parseGitUrl(gitUrl)
		local repoName = repoNameFromUrl(cloneUrl)
		local repoDir = getOrCloneRepo(repoName, cloneUrl, branch)

		-- Optional package name as first positional arg
		local packageName = args:pop()

		local pkg, err
		if packageName then
			pkg, err = findNamedPackageIn(repoDir, packageName)
		else
			pkg, err = Package.open(repoDir)
		end

		if not pkg then
			error(err)
		end

		local scriptArgs = args:drain() or {}
		executePackage(pkg, scriptArgs, userCwd)
	elseif localPath then
		local resolved = path.isAbsolute(localPath) and localPath or path.resolve(userCwd, localPath)

		-- Optional package name as first positional arg
		local packageName = args:pop()

		local pkg, err
		if packageName then
			pkg, err = findNamedPackageIn(resolved, packageName)
		else
			pkg, err = Package.open(resolved)
		end

		if not pkg then
			error(err)
		end

		local scriptArgs = args:drain() or {}
		executePackage(pkg, scriptArgs, userCwd)
	else
		local name = args:pop()
		if name then
			ansi.printf("{yellow}lpm has no package registry yet. Use --git <url> or --path <dir> instead.")
		else
			ansi.printf("{red}Usage: lpm x --git <repo-url> [package-name] [args...]")
			ansi.printf("{red}       lpm x --path <dir> [package-name] [args...]")
		end
	end
end

return x
