local fs = require("fs")
local path = require("path")
local lua = require("lua-sys")

local state, chunk ---@type any?, any?

-- Runs inside the compiler guest: the tl module and the shared env stay
-- loaded in that state across compiles. Type errors never block codegen
-- (only syntax errors do); `tl check` remains the strict tool.
local DRIVER = [[
	local source, filename = ...
	local tl = require("tl")
	if not _lde_tl_env then
		_lde_tl_env = tl.init_env(false, false, "5.1")
	end
	local result = tl.process_string(source, false, _lde_tl_env, filename)
	if not result.ast then
		local msgs = {}
		for _, e in ipairs(result.syntax_errors or {}) do
			msgs[#msgs + 1] = string.format("%s:%d:%d: %s", e.filename or filename, e.y, e.x, e.msg)
		end
		return { err = table.concat(msgs, "\n") }
	end
	return { code = tl.generate(result.ast, _lde_tl_env.defaults.gen_target) }
]]

---@return any # the compiler guest state
local function ensureTL()
	if state then return state end
	local lde = require("lde-core")
	local util = require("lde-core.util")

	for attempt = 1, 2 do
		local pkg, _, err = util.openLuarocksPackage("tl")
		if not pkg then
			error("Failed to resolve the Teal compiler (luarocks:tl): " .. (err or "unknown error"))
		end
		pkg:build()
		pkg:installDependencies()

		-- Reuse the package path setup shared by the runner and build scripts.
		local luaPath, luaCPath = require("lde-core.package.run").getLuaPaths(pkg)
		local st = lua.new()
		local g = st:globals()
		g.package.path = luaPath
		g.package.cpath = luaCPath

		if pcall(st.eval, st, 'return require("tl")') then
			state = st
			chunk = st:load(DRIVER, "@lde-teal-compile")
			return st
		end
		st:close()

		if attempt == 2 then
			error("The Teal compiler installed but failed to load")
		end
		local url = util.resolveLuarocksSource("tl")
		if url then
			local archiveDir = lde.global.getArchiveDir(url)
			fs.rmdir(archiveDir)
			fs.delete(archiveDir .. ".archive")
		end
	end
	error("The Teal compiler could not be loaded")
end

---@param dir string
---@return boolean
local function hasTeal(dir)
	for _, rel in ipairs(fs.scan(dir, "**" .. path.separator .. "*.tl")) do
		if not rel:match("%.d%.tl$") then return true end
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

	ensureTL()
	local ok, result = pcall(chunk.eval, chunk, source, file)
	if not ok then return nil, tostring(result) end
	if result.err then return nil, result.err end
	return result.code
end

--- Compile every .tl under srcDir into outDir (mirroring the directory
--- structure) and copy everything else, so outDir is a drop-in Lua mirror of
--- srcDir. `.d.tl` declaration files are copied but not compiled.
---@param srcDir string
---@param outDir string
local function compileDir(srcDir, outDir)
	ensureTL()
	for _, rel in ipairs(fs.scan(srcDir, "**")) do
		local absSrc = path.join(srcDir, rel)
		if fs.isdir(absSrc) then
			mkdirp(path.join(outDir, rel))
		elseif rel:match("%.tl$") and not rel:match("%.d%.tl$") then
			local outRel = rel:gsub("%.tl$", ".lua")
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

return {
	compileFile = compileFile,
	hasTeal = hasTeal,
	compileDir = compileDir,
}
