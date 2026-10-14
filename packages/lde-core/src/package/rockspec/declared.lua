--- The post-build copy pass every backend runs: rockspec `build.install.{lib,lua,bin}`
--- entries and `build.copy_directories`, mirroring LuaRocks' install_files.

const fs = require("fs")
local path = require("path")

const native = require("lde-core.package.rockspec.native")

local declared = {}

--- Copies the files a rockspec's build.install table declares. A numeric key
--- installs the file under its own basename; a string key names the module
--- (lib/lua: dots become directories, a .lua source is renamed after the module)
--- or the destination path inside the directory (bin).
---
--- A file the backend already materialized at the destination counts as produced:
--- make rocks install into the module dir and still list the file under its
--- build-tree path. A declared file that exists nowhere is an error (LuaRocks:
--- "Failed copying <file>") — skipping it silently reported a successful install
--- for a package that installed nothing.
---@param files table<integer|string, string> # build.install.lib/.lua/.bin
---@param destRoot string # module dir (lib/lua) or the package's target dir (bin)
---@param rockDir string # rock source dir the entries are relative to
---@param isModulePath boolean # whether a string key names a module
---@return boolean?
---@return string?
function declared.installFiles(files, destRoot, rockDir, isModulePath)
	if next(files) == nil then return true end

	for key, src in pairs(files) do
		local destDir = destRoot
		local destName = path.basename(src)
		if type(key) == "string" then
			if isModulePath then
				destDir = path.join(destRoot, key:gsub("%.", path.separator))
				if destName:match("%.lua$") then
					destName = key:match("([^.]+)$") .. ".lua"
				end
			else
				const keyDir = path.dirname(key)
				destDir = keyDir ~= "." ? path.join(destRoot, keyDir) : destRoot
				destName = path.basename(key)
			end
		end

		const srcAbs = path.join(rockDir, src)
		const destAbs = path.join(destDir, destName)
		if fs.isfile(destAbs) and not fs.isfile(srcAbs) then
			goto continue
		end
		if not fs.isdir(destDir) then fs.mkdirAll(destDir) end
		-- fs.copy can report success without writing, so verify the file landed.
		if not fs.copy(srcAbs, destAbs) or not fs.isfile(destAbs) then
			return nil, "Failed to install '" .. src .. "' from '" .. srcAbs .. "'"
		end
		-- LuaRocks installs bin entries executable.
		if not isModulePath and jit.os ~= "Windows" then
			fs.chmod(destAbs, tonumber("755", 8))
		end
		::continue::
	end

	return true
end

--- build.install.lua entries: installed into the module dir with the file's
--- extension preserved (a numeric key keeps the basename, e.g. "tl.tl" becomes
--- module "tl"). Teal rocks ship .tl/.d.tl this way, and the sources must land next
--- to the compiled modules so `tl check -I target` resolves the rock's types.
---@param files table<integer|string, string>
---@param modulesDir string
---@param rockDir string
function declared.installLuaSources(files, modulesDir, rockDir)
	for modname, src in pairs(files) do
		if not src:match("%.lua$") and not src:match("%.tl$") then
			goto continue
		end
		const srcBase = path.basename(src)
		-- .d.tl declaration files keep both suffixes; others keep their last one.
		const ext = srcBase:match("%.d%.tl$") ? "d.tl" : srcBase:match("%.([^%.]+)$")
		const modBase = ext ? (srcBase:sub(1, -#ext - 2)) : srcBase
		if type(modname) == "number" then
			modname = modBase
		end
		local destAbs = path.join(modulesDir, (modname:gsub("%.", path.separator)) .. "." .. ext)
		const destDir = path.dirname(destAbs)
		if not fs.isdir(destDir) then fs.mkdirAll(destDir) end
		fs.copy(path.join(rockDir, src), destAbs)
		::continue::
	end
end

--- copy_directories: ship non-module assets (e.g. luacov's HTML reporter static
--- files) preserving their relative layout.
---@param copyDirs string[]
---@param modulesDir string
---@param rockDir string
function declared.copyDirectories(copyDirs, modulesDir, rockDir)
	for _, copyDir in ipairs(copyDirs) do
		const srcAbs = path.join(rockDir, copyDir)
		const destAbs = path.join(modulesDir, copyDir)
		if fs.isdir(srcAbs) then
			fs.mkdirAll(destAbs)
			fs.copy(srcAbs, destAbs)
		end
	end
end

--- The build.install.{lib,lua,bin} pass every backend ends with.
---@param ctx lde.rockspec.BuildContext
---@return boolean?
---@return string?
function declared.installAll(ctx)
	local ok, err = declared.installFiles(ctx.installLibFiles, ctx.modulesDir, ctx.dir, true)
	if not ok then return nil, err end
	declared.installLuaSources(ctx.installLuaFiles, ctx.modulesDir, ctx.dir)
	return declared.installFiles(ctx.binScripts, ctx.outputDir, ctx.dir, false)
end

--- Module sources copied into the module dir, plus their Teal twins.
---@param modules table<string, string>
---@param modulesDir string
---@param rockDir string
---@return boolean?
---@return string?
function declared.installModules(modules, modulesDir, rockDir)
	for modname, src in pairs(modules) do
		local srcBase = path.basename(src)
		local destAbs
		if srcBase == "init.lua" then
			-- "system.init" installs as system/init.lua
			const dirPath = modname:match("^(.+)%.init$")
			destAbs = dirPath
				and path.join(modulesDir, dirPath:gsub("%.", path.separator), "init.lua")
				or path.join(modulesDir, modname:gsub("%.", path.separator), "init.lua")
		else
			destAbs = path.join(modulesDir, modname:gsub("%.", path.separator) .. ".lua")
		end
		const destDir = path.dirname(destAbs)
		if not fs.isdir(destDir) then fs.mkdirAll(destDir) end
		-- fs.copy returns true even when the write silently failed (e.g. a module
		-- path colliding with the package's own target/<name> dir).
		const srcAbs = path.join(rockDir, src)
		if not fs.copy(srcAbs, destAbs) or not fs.isfile(destAbs) then
			return nil, "Failed to install module source '" .. src .. "' for module '" .. modname .. "'"
		end
		for _, tlSuffix in ipairs(native.TL_SOURCE_SUFFIXES) do
			const srcTl = srcAbs:gsub("%.lua$", "." .. tlSuffix)
			if fs.isfile(srcTl) then
				fs.copy(srcTl, destAbs:gsub("%.lua$", "." .. tlSuffix))
			end
		end
	end
	return true
end

return declared
