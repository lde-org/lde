--- Shared machinery for compilers that turn a source language into Lua
--- (Moonscript, Teal, ...). A language is a spec; the compiler guest state
--- that runs the translator stays loaded across compiles.
---
--- The guest state is created once per process: the compiler package is
--- resolved via luarocks, built, and installed as a dependency, then the
--- driver chunk is loaded into a fresh lua-sys state with the package path
--- the runner would use. Every subsequent compile reuses that state.
---
---@class lde.CompilerSpec
---@field name string # language name for error messages ("Moonscript", "Teal")
---@field packageName string # luarocks package providing the compiler
---@field loadExpr string # expression evaluated to verify the compiler loads
---@field extension string # source file extension (".moon", ".tl")
---@field driver string # chunk body: receives (source, filename), returns { code } or { err }
---@field matchSource fun(rel: string): boolean # true when rel is a compilable source file
---@field outRel fun(rel: string): string # output path for a matched source file
---@field hasSourceFilter (fun(rel: string): boolean)? # extra filter for hasSource scans
---@field writeExtras fun(outDir: string, rel: string, source: string)? # extra outputs beside the compiled file

---@class lde.Compiler
---@field spec lde.CompilerSpec
---@field state lua.State?
---@field chunk lua.Chunk?
local Compiler = {}
Compiler.__index = Compiler

local fs = require("fs")
local path = require("path")
local lua = require("lua-sys")

local errorMod = require("lde-core.error")

---@param spec lde.CompilerSpec
---@return lde.Compiler
function Compiler.new(spec)
	return setmetatable({ spec = spec }, Compiler)
end

---@param dir string
local function mkdirp(dir)
	if fs.isdir(dir) then return end
	mkdirp(path.dirname(dir))
	fs.mkdir(dir)
end

--- Ensure the compiler guest state exists, resolving + building the compiler
--- package first if needed. Retries once after clearing the cached archive,
--- in case the first resolution produced a broken install.
---@return lua.State
function Compiler:ensure()
	if self.state then return self.state end

	local ldeUtil = require("lde-core.util")
	for attempt = 1, 2 do
		local pkg, _, err = ldeUtil.openLuarocksPackage(self.spec.packageName)
		if not pkg then
			errorMod.raise("Failed to resolve the " .. self.spec.name .. " compiler (luarocks:" .. self.spec.packageName .. "): " .. (err or "unknown error"))
		end ---@cast pkg -nil

		pkg:build()
		pkg:installDependencies()

		-- Reuse the package path setup shared by the runner and build scripts.
		local luaPath, luaCPath = require("lde-core.package.run").getLuaPaths(pkg)
		local st = lua.new()
		local g = st:globals() --[[@as { package: { path: string?, cpath: string? } }]]
		g.package.path = luaPath
		g.package.cpath = luaCPath

		if pcall(st.eval, st, self.spec.loadExpr) then
			self.state = st
			self.chunk = st:load(self.spec.driver, "@lde-" .. self.spec.packageName .. "-compile")
			return st
		end
		st:close()

		if attempt == 2 then
			errorMod.raise("The " .. self.spec.name .. " compiler installed but failed to load")
		end

		local url = ldeUtil.resolveLuarocksSource(self.spec.packageName)
		if url then
			local archiveDir = require("lde-core.global").getArchiveDir(url)
			fs.rmdir(archiveDir)
			fs.delete(archiveDir .. ".archive")
		end
	end

	errorMod.raise("The " .. self.spec.name .. " compiler could not be loaded")
	error("unreachable", 0)
end

--- Whether a directory contains any source files in this language.
---@param dir string
---@return boolean
function Compiler:hasSource(dir)
	if not fs.isdir(dir) then return false end
	for _, rel in ipairs(fs.scan(dir, "**" .. path.separator .. "*" .. self.spec.extension)) do
		if not self.spec.hasSourceFilter or self.spec.hasSourceFilter(rel) then
			return true
		end
	end
	return false
end

---@param source string
---@param file string
---@return string? code
---@return string? err
function Compiler:compileSource(source, file)
	self:ensure()
	local ok, result = pcall(self.chunk.eval, self.chunk, source, file)
	if not ok then return nil, tostring(result) end
	if result.err then return nil, result.err end
	return result.code
end

---@param file string
---@return string? code
---@return string? err
function Compiler:compileFile(file)
	local source = fs.read(file)
	if not source then return nil, "Failed to read " .. file end
	return self:compileSource(source, file)
end

--- Compile every source file under srcDir into outDir (mirroring the
--- directory structure) and copy everything else, so outDir is a drop-in Lua
--- mirror of srcDir.
---@param srcDir string
---@param outDir string
function Compiler:compileDir(srcDir, outDir)
	self:ensure()
	for _, rel in ipairs(fs.scan(srcDir, "**")) do
		local absSrc = path.join(srcDir, rel)
		if fs.isdir(absSrc) then
			mkdirp(path.join(outDir, rel))
		elseif self.spec.matchSource(rel) then
			local outPath = path.join(outDir, self.spec.outRel(rel))
			mkdirp(path.dirname(outPath))
			local source = fs.read(absSrc)
			if not source then
				errorMod.raise("Failed to read " .. absSrc)
			end ---@cast source -nil
			local code, err = self:compileSource(source, absSrc)
			if not code then
				errorMod.raise("Failed to compile " .. absSrc .. ":\n" .. (err or "unknown error"))
			end
			fs.write(outPath, code --[[@as string]])
			if self.spec.writeExtras then
				self.spec.writeExtras(outDir, rel, source --[[@as string]])
			end
		else
			local outPath = path.join(outDir, rel)
			mkdirp(path.dirname(outPath))
			local content = fs.read(absSrc)
			if content then fs.write(outPath, content) end
		end
	end
end

return Compiler
