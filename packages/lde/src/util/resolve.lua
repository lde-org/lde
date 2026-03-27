local env = require("env")
local path = require("path")

local lde = require("lde-core")

--- Resolves a rocks: name to a Package
---@param name string e.g. "rocks:busted@2.0"
---@return lde.Package?, string?
local function resolveRocks(name)
	local rocksName, versionStr = name:match("^rocks:([^@]+)@?(.*)$")
	versionStr = versionStr ~= "" and versionStr or nil

	local pkg, _, err = lde.util.openLuarocksPackage(rocksName, versionStr)
	return pkg, err
end

--- Resolves --git, --path, or a registry/rocks: name to a Package.
--- Returns pkg, err, extraName (the popped sub-package name for git/path)
---@param args clap.Args
---@return lde.Package?, string?, string?
local function resolvePackage(args)
	local gitUrl = args:option("git")
	local localPath = args:option("path")
	local userCwd = env.cwd()

	if gitUrl then
		local cloneUrl, branch = lde.global.parseGitUrl(gitUrl)
		local repoName = lde.global.repoNameFromUrl(cloneUrl)
		local repoDir = lde.global.getOrCloneRepo(repoName, cloneUrl, branch)

		local packageName = args:pop()
		if packageName then
			return lde.global.findNamedPackageIn(repoDir, packageName)
		else
			return lde.Package.open(repoDir)
		end
	elseif localPath then
		local resolved = path.isAbsolute(localPath) and localPath or path.resolve(userCwd, localPath)

		local packageName = args:pop()
		if packageName then
			return lde.global.findNamedPackageIn(resolved, packageName)
		else
			return lde.Package.open(resolved)
		end
	else
		local name = args:pop()
		if not name then return nil, "no name" end

		if name:match("^rocks:") then
			return resolveRocks(name)
		end

		local packageName, versionStr = name:match("^([^@]+)@(.+)$")
		if not packageName then packageName = name end

		lde.global.syncRegistry()
		local portfile, err = lde.global.lookupRegistryPackage(packageName)
		if not portfile then return nil, err end

		local _, commit = lde.global.resolveRegistryVersion(portfile, versionStr or nil)
		local repoDir = lde.global.getOrInitGitRepo(packageName, portfile.git, portfile.branch, commit)
		return lde.Package.open(repoDir)
	end
end

return resolvePackage
