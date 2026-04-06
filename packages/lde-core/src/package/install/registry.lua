local fs = require("fs")
local path = require("path")
local lde = require("lde-core")

---@param alias string
---@param packageName string
---@param depInfo lde.Package.Config.RegistryDependency
---@return lde.Package, lde.Lockfile.GitDependency
local function resolve(alias, packageName, depInfo)
	lde.global.syncRegistry()

	local portfile, err = lde.global.lookupRegistryPackage(packageName)
	if not portfile then
		error("Registry lookup failed for '" .. alias .. "': " .. err)
	end

	local _, commit = lde.global.resolveRegistryVersion(portfile, depInfo.version)
	local repoDir = lde.global.getOrInitGitRepo(packageName, portfile.git, portfile.branch, commit)

	---@type lde.Lockfile.GitDependency
	local lockEntry = { git = portfile.git, commit = commit, branch = portfile.branch, name = depInfo.name }

	local pkg = lde.Package.open(repoDir, depInfo.rockspec)
	if pkg and pkg:getName() == packageName then
		return pkg, lockEntry
	end

	for _, config in ipairs(fs.scan(repoDir, "**" .. path.separator .. "lde.json")) do
		pkg = lde.Package.open(path.join(repoDir, path.dirname(config)))
		if pkg and pkg:getName() == packageName then
			return pkg, lockEntry
		end
	end

	error("No lde.json with name '" .. packageName .. "' found in registry package '" .. alias .. "'")
end

return resolve
