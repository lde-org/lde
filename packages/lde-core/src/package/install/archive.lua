local lde = require("lde-core")

---@param alias string
---@param depInfo lde.Package.Config.ArchiveDependency
---@return lde.Package, lde.Lockfile.ArchiveDependency
local function resolve(alias, depInfo)
	local archiveDir = lde.global.getOrInitArchive(depInfo.archive)
	local pkg, err = lde.Package.open(archiveDir, depInfo.rockspec)
	if not pkg then
		error("Failed to load archive dependency '" .. alias .. "': " .. (err or ""))
	end
	return pkg, { archive = depInfo.archive, name = depInfo.name, rockspec = depInfo.rockspec }
end

return resolve
