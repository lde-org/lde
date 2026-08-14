local env = require("env")
local fs = require("fs")
local path = require("path")

local lde = require("lde-core")

--- Resolves a rocks: name to a Package
---@param name string e.g. "rocks:busted@2.0"
---@param offline boolean?
---@return lde.Package?, string?
local function resolveRocks(name, offline)
	local rocksName, versionStr = name:match("^rocks:([^@]+)@?(.*)$")
	versionStr = versionStr ~= "" and versionStr or nil

	local pkg, _, err = lde.util.openLuarocksPackage(rocksName, versionStr, offline)
	return pkg, err
end

--- Resolves --git, --path, or a registry/rocks: name to a Package.
--- Returns pkg, err, extraName (the popped sub-package name for git/path)
---@param args clap.Args
---@param parsed { git: string?, path: string?, offline: boolean? }? # Pre-consumed --git/--path/--offline values (the install command peeks them to decide its project-install branch)
---@return lde.Package?, string?, string?
local function resolvePackage(args, parsed)
	local offline = (parsed and parsed.offline) or args:flag("offline")
	local gitUrl = parsed and parsed.git or args:option("git")
	local localPath = parsed and parsed.path or args:option("path")
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
			return resolveRocks(name, offline)
		end

		local packageName, versionStr = name:match("^([^@]+)@(.+)$")
		if not packageName then packageName = name end

		if not offline then
			lde.global.syncRegistry()
		elseif not fs.exists(lde.global.getRegistryDir()) then
			return nil, "offline: lde registry is not cached (run `lde x " .. packageName .. "` online once to cache it)"
		end

		local portfile, err = lde.global.lookupRegistryPackage(packageName)
		if not portfile then return nil, err end

		local _, commit = lde.global.resolveRegistryVersion(portfile, versionStr or nil)
		local repoDir
		if offline then
			repoDir = lde.global.getGitRepoDir(packageName, commit)
			if not fs.exists(repoDir) then
				return nil, "offline: '" .. packageName .. "' is not cached locally (run `lde x " .. packageName .. "` online once to cache it)"
			end
		else
			repoDir = lde.global.getOrInitGitRepo(packageName, portfile.git, portfile.branch, commit)
		end
		return lde.Package.open(repoDir)
	end
end

return resolvePackage
