local sea = require("sea")
local fs = require("fs")
local path = require("path")

local lde = require("lde-core")

local bundlePackage = require("lde-core.package.bundle")

local nativeExt = jit.os == "Windows" and "dll"
	or jit.os == "OSX" and "dylib"
	or "so"

---@param package lde.Package
local function compilePackage(package)
	package:build()
	package:installDependencies()

	-- Bytecode bundles skip the parser at startup: sea embeds the bytecode as a
	-- raw blob (.incbin) and luaL_loadbuffer detects it without parsing.
	local source = bundlePackage(package, { bytecode = true })

	local sharedLibs = {}
	local modulesDir = package:getModulesDir()

	for entry in fs.readdir(modulesDir) do
		local p = path.join(modulesDir, entry.name)
		if not fs.isdir(p) then
			if entry.name:match("%." .. nativeExt .. "$") then
				local content = fs.read(p)
				if not content then error("Could not read file: " .. p) end
				local moduleName = entry.name:gsub("%." .. nativeExt .. "$", "")
				table.insert(sharedLibs, { name = moduleName, content = content })
			end
			goto continue
		end

		for _, relativePath in ipairs(fs.scan(p, "**" .. path.separator .. "*." .. nativeExt)) do
			local absPath = path.join(p, relativePath)
			local content = fs.read(absPath)
			if not content then error("Could not read file: " .. absPath) end

			local moduleName = string.gsub(relativePath, path.separator, "."):gsub("%." .. nativeExt .. "$", "")
			moduleName = moduleName ~= "" and (entry.name .. "." .. moduleName) or entry.name
			table.insert(sharedLibs, { name = moduleName, content = content })
		end

		::continue::
	end

	return sea.compile(package:getName(), source, sharedLibs, lde.global.getGCCBin())
end

return compilePackage
