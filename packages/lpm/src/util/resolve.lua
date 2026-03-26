local env = require("env")
local luarocks = require("luarocks")
local path = require("path")

local lpm = require("lpm-core")

--- Resolves a rocks: name to a Package
---@param name string e.g. "rocks:busted@2.0"
---@return lpm.Package?, string?
local function resolveRocks(name)
	local rocksName, versionStr = name:match("^rocks:([^@]+)@?(.*)$")
	versionStr = versionStr ~= "" and versionStr or nil

	local url, err = luarocks.getRockspecUrl(rocksName, versionStr)
	if not url then return nil, err end

	local pkg, _, pkgErr = lpm.util.openRockspecUrl(rocksName, url)
	return pkg, pkgErr
end

--- Resolves --git, --path, or a registry/rocks: name to a Package.
--- Returns pkg, err, extraName (the popped sub-package name for git/path)
---@param args clap.Args
---@return lpm.Package?, string?, string?
local function resolvePackage(args)
	local gitUrl = args:option("git")
	local localPath = args:option("path")
	local userCwd = env.cwd()

	if gitUrl then
		local cloneUrl, branch = lpm.global.parseGitUrl(gitUrl)
		local repoName = lpm.global.repoNameFromUrl(cloneUrl)
		local repoDir = lpm.global.getOrCloneRepo(repoName, cloneUrl, branch)

		local packageName = args:pop()
		if packageName then
			return lpm.global.findNamedPackageIn(repoDir, packageName)
		else
			return lpm.Package.open(repoDir)
		end
	elseif localPath then
		local resolved = path.isAbsolute(localPath) and localPath or path.resolve(userCwd, localPath)

		local packageName = args:pop()
		if packageName then
			return lpm.global.findNamedPackageIn(resolved, packageName)
		else
			return lpm.Package.open(resolved)
		end
	else
		local name = args:pop()
		if not name then return nil, "no name" end

		if name:match("^rocks:") then
			return resolveRocks(name)
		end

		local packageName, versionStr = name:match("^([^@]+)@(.+)$")
		if not packageName then packageName = name end

		lpm.global.syncRegistry()
		local portfile, err = lpm.global.lookupRegistryPackage(packageName)
		if not portfile then return nil, err end

		local _, commit = lpm.global.resolveRegistryVersion(portfile, versionStr or nil)
		local repoDir = lpm.global.getOrInitGitRepo(packageName, portfile.git, portfile.branch, commit)
		return lpm.Package.open(repoDir)
	end
end

return resolvePackage
