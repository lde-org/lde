local fs = require("fs")
local path = require("path")

local tlModule ---@type any?
local env ---@type any?

---@return any
local function ensureTL()
	local lde = require("lde-core")
	local util = require("lde-core.util")

	for attempt = 1, 2 do
		local pkg, _, err = util.openLuarocksPackage("tl")
		if not pkg then
			error("Failed to resolve the Teal compiler (luarocks:tl): " .. (err or "unknown error"))
		end
		pkg:build()
		pkg:installDependencies()

		local tree = pkg:getModulesDir()
		local oldPath = package.path
		package.path = path.join(tree, "?.lua") .. ";" .. path.join(tree, "?", "init.lua") .. ";" .. oldPath
		local ok, tl = pcall(require, "tl")
		package.path = oldPath
		if ok then return tl end

		if attempt == 2 then
			error("The Teal compiler installed but failed to load: " .. tostring(tl))
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

---@return any
local function init()
	if tlModule then return tlModule end
	local ok, tl = pcall(require, "tl")
	if not ok then
		tl = ensureTL()
	end
	tlModule = tl
	env = tl.init_env(false, false, "5.1")
	return tlModule
end

---@param source string
---@param filename string?
---@return string? code
---@return string? err
local function compile(source, filename)
	local tl = init()
	local result = tl.process_string(source, false, env, filename or "?")
	if not result.ast then
		local msgs = {}
		for _, e in ipairs(result.syntax_errors or {}) do
			msgs[#msgs + 1] = string.format("%s:%d:%d: %s", e.filename or filename or "?", e.y, e.x, e.msg)
		end
		return nil, table.concat(msgs, "\n")
	end
	return tl.generate(result.ast, env.defaults.gen_target)
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

---@param srcDir string
---@param outDir string
local function compileDir(srcDir, outDir)
	init()
	for _, rel in ipairs(fs.scan(srcDir, "**")) do
		local absSrc = path.join(srcDir, rel)
		if fs.isdir(absSrc) then
			mkdirp(path.join(outDir, rel))
		elseif rel:match("%.tl$") and not rel:match("%.d%.tl$") then
			local outRel = rel:gsub("%.tl$", ".lua")
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
	hasTeal = hasTeal,
	compileDir = compileDir,
}
