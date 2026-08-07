local fs = require("fs")
local path = require("path")

local base ---@type any?

---@return any
local function ensureMoon()
	local lde = require("lde-core")
	local util = require("lde-core.util")

	for attempt = 1, 2 do
		local pkg, _, err = util.openLuarocksPackage("moonscript")
		if not pkg then
			error("Failed to resolve the Moonscript compiler (luarocks:moonscript): " .. (err or "unknown error"))
		end
		pkg:build()
		pkg:installDependencies()

		local tree = pkg:getModulesDir()
		local oldPath, oldCPath = package.path, package.cpath
		package.path = path.join(tree, "?.lua") .. ";" .. path.join(tree, "?", "init.lua") .. ";" .. oldPath
		package.cpath = path.join(tree, "?.so") .. ";" .. path.join(tree, "?", "?.so") .. ";" .. oldCPath
		local ok, mod = pcall(require, "moonscript.base")
		package.path, package.cpath = oldPath, oldCPath
		if ok then return mod end

		if attempt == 2 then
			error("The Moonscript compiler installed but failed to load: " .. tostring(mod))
		end
		local url = util.resolveLuarocksSource("moonscript")
		if url then
			local archiveDir = lde.global.getArchiveDir(url)
			fs.rmdir(archiveDir)
			fs.delete(archiveDir .. ".archive")
		end
	end
	error("The Moonscript compiler could not be loaded")
end

---@return any
local function init()
	if base then return base end
	local ok, mod = pcall(require, "moonscript.base")
	if not ok then
		mod = ensureMoon()
	end
	base = mod
	return base
end

---@param source string
---@param _filename string?
---@return string? code
---@return string? err
local function compile(source, _filename)
	local base = init()
	local code, err = base.to_lua(source)
	if not code then
		return nil, err or "unknown error"
	end
	return code
end

---@param dir string
---@return boolean
local function hasMoon(dir)
	for _ in ipairs(fs.scan(dir, "**" .. path.separator .. "*.moon")) do
		return true
	end
	return false
end

---@param dir string
local function mkdirp(dir)
	if fs.isdir(dir) then return end
	mkdirp(path.dirname(dir))
	fs.mkdir(dir)
end

---@param srcDir string
---@param outDir string
local function compileDir(srcDir, outDir)
	init()
	for _, rel in ipairs(fs.scan(srcDir, "**")) do
		local absSrc = path.join(srcDir, rel)
		if fs.isdir(absSrc) then
			mkdirp(path.join(outDir, rel))
		elseif rel:match("%.moon$") then
			local outRel = rel:gsub("%.moon$", ".lua")
			mkdirp(path.dirname(path.join(outDir, outRel)))
			local source = fs.read(absSrc)
			if not source then
				error("Failed to read " .. absSrc)
			end
			local code, err = compile(source, absSrc)
			if not code then
				error("Failed to compile " .. absSrc .. ":\n" .. (err or "unknown error"))
			end
			fs.write(path.join(outDir, outRel), code)
		else
			local outPath = path.join(outDir, rel)
			mkdirp(path.dirname(outPath))
			local content = fs.read(absSrc)
			if content then fs.write(outPath, content) end
		end
	end
end

return {
	compile = compile,
	hasMoon = hasMoon,
	compileDir = compileDir,
}
