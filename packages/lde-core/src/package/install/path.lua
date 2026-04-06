local path = require("path")
local lde = require("lde-core")

---@param alias string
---@param depInfo lde.Package.Config.PathDependency
---@param relativeTo string
---@return lde.Package, lde.Lockfile.Dependency
local function resolve(alias, depInfo, relativeTo)
	local pkg, err = lde.Package.open(path.resolve(relativeTo, path.normalize(depInfo.path)), depInfo.rockspec)
	if not pkg then
		error("Failed to load local dependency package for: " .. alias .. "\nError: " .. err)
	end
	return pkg, { path = depInfo.path, name = depInfo.name, rockspec = depInfo.rockspec }
end

return resolve
