local fs = require("fs")
local path = require("path")
local ansi = require("ansi")
local lde = require("lde-core")

---@type table<lde.Package, boolean>
local currentlyBuilding = setmetatable({}, { __mode = "k" })
---@type table<string, boolean>
local alreadyBuilt = {}

---@param package lde.Package
---@param destinationPath string?
local function buildPackage(package, destinationPath)
	if currentlyBuilding[package] then return end
	currentlyBuilding[package] = true

	destinationPath = destinationPath or path.join(package:getModulesDir(), package:getName())

	local target = path.dirname(destinationPath)
	if not fs.isdir(target) then fs.mkdir(target) end

	if package:hasBuildScript() then
		-- If a symlink exists from a previous no-build-script run, remove it
		-- before the build script tries to write into destinationPath as a dir.
		if fs.islink(destinationPath) then fs.delete(destinationPath) end

		-- Check stamp before showing progress so already-built packages are silent
		local stampFile = path.join(destinationPath, ".lde-built")
		local alreadyDone = alreadyBuilt[destinationPath] or fs.exists(stampFile)
		local p = (lde.verbose and not alreadyDone) and ansi.progress("Building " .. package:getName()) or nil
		local ok, err = package:runBuildScript(destinationPath)
		if not ok then
			if p then p:fail("Building " .. package:getName()) end
			error("Build script failed for package '" .. package:getName() .. "': " .. err)
		end
		if p then p:done("Built " .. package:getName()) end
		alreadyBuilt[destinationPath] = true
	else
		-- If a real directory exists from a previous build-script run, remove it
		-- before creating the symlink.
		if fs.isdir(destinationPath) and not fs.islink(destinationPath) then
			fs.rmdir(destinationPath)
		end
		fs.mklink(package:getSrcDir(), destinationPath)
	end

	currentlyBuilding[package] = nil
end

return buildPackage
