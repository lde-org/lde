local lde = require("lde-core")

---@param alias string
---@param depInfo lde.Package.Config.LuarocksDependency
---@return lde.Package, lde.Lockfile.Dependency
local function resolve(alias, depInfo)
	local pkg, lockEntry, err = lde.util.openLuarocksPackage(depInfo.luarocks, depInfo.version)
	if not pkg then
		error("Failed to resolve luarocks dep '" .. alias .. "': " .. (err or ""))
	end ---@cast lockEntry -nil
	lockEntry.name = depInfo.name
	return pkg, lockEntry
end

return resolve
