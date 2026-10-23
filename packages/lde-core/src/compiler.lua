--- A language is a spec; the compiler guest state is created once per process (compiler package resolved via luarocks, built, installed, then the driver chunk loaded into a fresh lua-sys state) and reused across compiles.
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
const Compiler = {}
Compiler.__index = Compiler

const fs = require("fs")
const path = require("path")
const lua = require("lua-sys")

const errorMod = require("lde-core.error")

---@param spec lde.CompilerSpec
function Compiler.new(spec)
	return setmetatable({ spec = spec }, Compiler)
end

---@param dir string
local function mkdirp(dir)
	if fs.isdir(dir) then return end
	mkdirp(path.dirname(dir))
	fs.mkdir(dir)
end

--- Resolves, builds and loads the compiler once, retrying after retiring the
--- cached src rock when the install or load failed (a concurrent shard may have
--- cleaned or rewritten the shared cache entry under us).
---@return lua.State
function Compiler:ensure()
	if self.state then return self.state end

	const ldeUtil = require("lde-core.util")
	for attempt = 1, 2 do
		local pkg, _, err = ldeUtil.openLuarocksPackage(self.spec.packageName)
		if not pkg then
			errorMod.raise("Failed to resolve the " .. self.spec.name .. " compiler (luarocks:" .. self.spec.packageName .. "): " .. (err or "unknown error"))
		end ---@cast pkg -nil

		-- A build can fail when another process retires the shared cache tree
		-- mid-build; the retry below re-resolves it, so treat that like a load
		-- failure instead of aborting the shard. build is synchronous here: it
		-- waits for any spawned native compile before we require the tree.
		const ok, stateOrErr, loadErr = pcall(function()
			pkg:build()
			pkg:installDependencies()

			const luaPath, luaCPath = require("lde-core.package.run").getLuaPaths(pkg)
			local st = lua.new()
			const g = st:globals() --[[@as { package: { path: string?, cpath: string? } }]]
			g.package.path = luaPath
			g.package.cpath = luaCPath

			const loaded, evalErr = pcall(st.eval, st, self.spec.loadExpr)
			if not loaded then
				st:close()
				return nil, evalErr
			end
			return st
		end)

		if ok and stateOrErr ~= nil then
			self.state = stateOrErr
			self.chunk = stateOrErr:load(self.spec.driver, "@lde-" .. self.spec.packageName .. "-compile")
			return stateOrErr
		end

		if attempt == 2 then
			const reason = ok and (loadErr or "unknown error") or stateOrErr
			errorMod.raise("The " .. self.spec.name .. " compiler could not be installed or loaded: "
				.. tostring(reason))
		end

		const url = ldeUtil.resolveLuarocksSource(self.spec.packageName)
		if url then
			const archiveDir = require("lde-core.global").getArchiveDir(url)
			-- Retire the cached entry instead of deleting it in place: this runs while
			-- other processes (parallel test shards, another terminal) may be reading
			-- the same directory — a recursive delete lets them scan a half-emptied
			-- tree and fail with "No rockspec found in src rock". The build lock
			-- serializes with an in-place build, but only when the entry still exists:
			-- acquiring it creates the parent chain, and resurrecting a retired cache
			-- dir would leave an empty entry that resolution trusts as complete.
			const lock = require("lde-core.package.install.lock")
			const handle = lock.acquire(path.join(archiveDir, self.spec.packageName, "target", self.spec.packageName),
				{ createParent = false })
			ldeUtil.retireCacheDir(archiveDir)
			-- The downloaded .archive is left in place: it is a shared cache entry and
			-- another process may be extracting those same bytes right now.
			lock.release(handle)
		end
	end

	errorMod.raise("The " .. self.spec.name .. " compiler could not be loaded")
	error("unreachable", 0)
end

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
	const ok, result = pcall(self.chunk.eval, self.chunk, source, file)
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

--- Mirrors srcDir into outDir as Lua (directory structure preserved); everything else is copied verbatim.
---@param srcDir string
---@param outDir string
function Compiler:compileDir(srcDir, outDir)
	self:ensure()
	for _, rel in ipairs(fs.scan(srcDir, "**")) do
		const absSrc = path.join(srcDir, rel)
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
			const content = fs.read(absSrc)
			if content then fs.write(outPath, content) end
		end
	end
end

return Compiler
