local env = require("env")
local fs = require("fs")
local path = require("path")

local lde = require("lde-core")
local gitShorthand = require("lde.util.gitShorthand")

--- Resolves a rocks: name to a Package
---@param name string e.g. "rocks:busted@2.0"
---@param isOffline boolean?
---@return lde.Package?, string?
local function resolveRocks(name, isOffline)
	local rocksName, versionStr = name:match("^rocks:([^@]+)@?(.*)$")
	versionStr = versionStr ~= "" and versionStr or nil

	local pkg, _, err = lde.util.openLuarocksPackage(rocksName, versionStr, isOffline)
	return pkg, err
end

--- Resolves --git, --path, or a registry/rocks: name to a Package.
--- Returns pkg, err, extraName (the popped sub-package name for git/path)
---@param args clap.Args
---@param parsed { git: string?, path: string?, isOffline: boolean? }? # Pre-consumed --git/--path/--isOffline values (the install command peeks them to decide its project-install branch)
---@return lde.Package?, string?, string?
local function resolvePackage(args, parsed)
	local isOffline = (parsed and parsed.isOffline) or args:flag("offline")
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

		-- Git shorthand (gh:owner/repo, gh:<pkg>@owner/repo, github:...,
		-- codeberg:..., gitlab:...): behaves like `--git <url> [package-name]`.
		-- The <pkg>@ form carries the sub-package name in the shorthand itself;
		-- otherwise an optional positional is popped (a literal "--" is the arg
		-- separator, not a package name).
		local shorthandUrl, subPackage, serr = gitShorthand.expand(name)
		if serr then return nil, serr end
		if shorthandUrl then
			local cloneUrl, branch = lde.global.parseGitUrl(shorthandUrl)
			local repoName = lde.global.repoNameFromUrl(cloneUrl)
			local repoDir = lde.global.getOrCloneRepo(repoName, cloneUrl, branch)

			local subName = subPackage or args:pop()
			if subName == "--" then subName = nil end
			if subName then
				return lde.global.findNamedPackageIn(repoDir, subName)
			end
			return lde.Package.open(repoDir)
		end

		local packageName, versionStr = name:match("^([^@]+)@(.+)$")
		if not packageName then packageName = name end

		-- @latest always re-checks for the newest version, which needs the
		-- network — incompatible with --offline.
		if versionStr == "latest" and isOffline then
			return nil, "Cannot resolve '@latest' offline (it always checks for the newest version)"
		end

		if name:match("^rocks:") then
			local pkg, err = resolveRocks(name, isOffline)
			if not pkg then
				local rocksName = name:match("^rocks:([^@]+)") or name
				return nil, err, lde.util.suggestPackage(rocksName, true)
			end
			return pkg
		end

		if not isOffline then
			lde.global.syncRegistry()
		elseif not fs.exists(lde.global.getRegistryDir()) then
			return nil, "offline: lde registry is not cached (run `lde x " .. packageName .. "` online once to cache it)"
		end

		local portfile, err = lde.global.lookupRegistryPackage(packageName)
		if not portfile then
			return nil, err, lde.util.suggestPackage(packageName, false)
		end

		local _, commit = lde.global.resolveRegistryVersion(portfile, versionStr or nil)
		local repoDir
		if isOffline then
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
