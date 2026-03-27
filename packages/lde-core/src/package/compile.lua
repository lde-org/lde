local sea = require("sea")
local fs = require("fs")
local path = require("path")
local process = require("process")

local nativeExt = process.platform == "win32" and "dll"
	or process.platform == "darwin" and "dylib"
	or "so"

---@param package lde.Package
local function compilePackage(package)
	package:build()
	package:installDependencies()

	---@type table<{path: string, content: string}>
	local files = {}
	---@type table<{name: string, content: string}>
	local sharedLibs = {}

	---@param projectName string
	---@param dir string
	local function bundleDir(projectName, dir)
		for _, relativePath in ipairs(fs.scan(dir, "**" .. path.separator .. "*.lua")) do
			local absPath = path.join(dir, relativePath)
			local content = fs.read(absPath)
			if not content then
				error("Could not read file: " .. absPath)
			end

			-- Map file paths to Lua module names following the init.lua convention:
			-- init.lua -> projectName, foo/init.lua -> projectName.foo, etc.
			local moduleName = string.gsub(relativePath, path.separator, "."):gsub("%.lua$", ""):gsub("%.?init$", "")
			if moduleName ~= "" then
				moduleName = projectName .. "." .. moduleName
			else
				moduleName = projectName
			end

			table.insert(files, { path = moduleName, content = content })
		end

		for _, relativePath in ipairs(fs.scan(dir, "**" .. path.separator .. "*." .. nativeExt)) do
			local absPath = path.join(dir, relativePath)
			local content = fs.read(absPath)
			if not content then
				error("Could not read file: " .. absPath)
			end

			-- Map e.g. "socket/core.so" -> "socket.core"
			local moduleName = string.gsub(relativePath, path.separator, "."):gsub("%." .. nativeExt .. "$", "")
			if moduleName ~= "" then
				moduleName = projectName .. "." .. moduleName
			else
				moduleName = projectName
			end

			table.insert(sharedLibs, { name = moduleName, content = content })
		end
	end

	local modulesDir = package:getModulesDir()
	bundleDir(package:getName(), path.join(modulesDir, package:getName()))

	local lockfile = package:readLockfile()
	local deps = lockfile and lockfile:getDependencies() or package:getDependencies()
	for depName in pairs(deps) do
		bundleDir(depName, path.join(modulesDir, depName))
	end

	return sea.compile(package:getName(), files, sharedLibs)
end

return compilePackage
