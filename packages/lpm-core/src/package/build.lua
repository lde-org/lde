local fs = require("fs")
local path = require("path")

---@type table<lpm.Package, boolean>
local currentlyBuilding = setmetatable({}, { __mode = "k" })

---@param package lpm.Package
---@param destinationPath string?
local function buildPackage(package, destinationPath)
	if currentlyBuilding[package] then
		return
	end
	currentlyBuilding[package] = true

	destinationPath = destinationPath or path.join(package:getModulesDir(), package:getName())

	-- Ensure parent dir (target) exists
	local target = path.dirname(destinationPath)
	if not fs.isdir(target) then
		fs.mkdir(target)
	end

	if package:hasBuildScript() then
		local ok, err = package:runBuildScript(destinationPath)
		if not ok then
			error("Build script failed for package '" .. package:getName() .. "': " .. err)
		end
	else
		fs.mklink(package:getSrcDir(), destinationPath)
	end

	currentlyBuilding[package] = nil
end

return buildPackage
