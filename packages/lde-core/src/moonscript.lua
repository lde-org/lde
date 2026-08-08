local M = {}
package.loaded[(...)] = M

local fs = require("fs")
local path = require("path")
local lua = require("lua-sys")

local lde = require("lde-core")
local ldeUtil = require("lde-core.util")
local run = require("lde-core.package.run")

-- Runs inside the compiler guest: the moonscript module stays loaded in that
-- state across compiles. to_lua returns the compiled Lua or a formatted error.
local DRIVER = [[
	local source = ...
	local base = require("moonscript.base")
	local code, err = base.to_lua(source)
	if not code then
		return { err = err }
	end
	return { code = code }
]]

local state, chunk ---@type lua.State?, lua.Chunk?

---@return lua.State # the compiler guest state
local function ensureMoon()
	if state then return state end

	for attempt = 1, 2 do
		local pkg, _, err = ldeUtil.openLuarocksPackage("moonscript")
		if not pkg then
			error("Failed to resolve the Moonscript compiler (luarocks:moonscript): " .. (err or "unknown error"))
		end

		pkg:build()
		pkg:installDependencies()

		-- Reuse the package path setup shared by the runner and build scripts.
		local luaPath, luaCPath = run.getLuaPaths(pkg)
		local st = lua.new()
		local g = st:globals() --[[@as { package: { path: string?, cpath: string? } }]]
		g.package.path = luaPath
		g.package.cpath = luaCPath

		if pcall(st.eval, st, 'return require("moonscript.base")') then
			state = st
			chunk = st:load(DRIVER, "@lde-moon-compile")
			return st
		end
		st:close()

		if attempt == 2 then
			error("The Moonscript compiler installed but failed to load")
		end

		local url = ldeUtil.resolveLuarocksSource("moonscript")
		if url then
			local archiveDir = lde.global.getArchiveDir(url)
			fs.rmdir(archiveDir)
			fs.delete(archiveDir .. ".archive")
		end
	end

	error("The Moonscript compiler could not be loaded")
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

---@param file string
---@return string? code
---@return string? err
local function compileFile(file)
	local source = fs.read(file)
	if not source then return nil, "Failed to read " .. file end

	ensureMoon()
	local ok, result = pcall(chunk.eval, chunk, source, file)
	if not ok then return nil, tostring(result) end
	if result.err then return nil, result.err end
	return result.code
end

--- Compile every .moon under srcDir into outDir (mirroring the directory
--- structure) and copy everything else, so outDir is a drop-in Lua mirror of
--- srcDir.
---@param srcDir string
---@param outDir string
local function compileDir(srcDir, outDir)
	ensureMoon()
	for _, rel in ipairs(fs.scan(srcDir, "**")) do
		local absSrc = path.join(srcDir, rel)
		if fs.isdir(absSrc) then
			mkdirp(path.join(outDir, rel))
		elseif rel:match("%.moon$") then
			local outRel = rel:gsub("%.moon$", ".lua")
			mkdirp(path.dirname(path.join(outDir, outRel)))
			local code, err = compileFile(absSrc)
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

M.compileFile = compileFile
M.hasMoon = hasMoon
M.compileDir = compileDir
M.ensureMoon = ensureMoon

return M
