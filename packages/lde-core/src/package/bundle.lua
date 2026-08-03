local fs = require("fs")
local path = require("path")

local stringEscapes = {
	["\\"] = "\\\\",
	['"'] = '\\"',
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
	["\a"] = "\\a",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\v"] = "\\v"
}

---@param s string
---@return string
local function escapeString(s)
	return (string.gsub(s, '[\\\"\n\r\t\a\b\f\v]', stringEscapes))
end

---@param s string
---@return string
local function escapeBytes(s)
	return (string.gsub(s, ".", function(c)
		local b = string.byte(c)
		if b >= 32 and b < 127 and c ~= '"' and c ~= '\\' then
			return c
		end
		return string.format("\\x%02x", b)
	end))
end

---@param content string
---@param chunkName string
---@return string
local function compileBytecode(content, chunkName)
	local fn, err = loadstring(content, chunkName)
	if not fn then
		error("Failed to compile " .. chunkName .. ": " .. err)
	end
	return string.dump(fn)
end

---@param projectName string
---@param dir string
---@param files table<string, string>
local function bundleDir(projectName, dir, files)
	for _, relativePath in ipairs(fs.scan(dir, "**" .. path.separator .. "*.lua")) do
		local absPath = path.join(dir, relativePath)
		local content = fs.read(absPath)
		if not content then
			error("Could not read file: " .. absPath)
		end

		local moduleName = relativePath:gsub(path.separator, "."):gsub("%.lua$", ""):gsub("%.?init$", "")
		if moduleName ~= "" then
			moduleName = projectName .. "." .. moduleName
		else
			moduleName = projectName
		end

		files[moduleName] = content
	end
end

---@param package lde.Package
---@param opts { bytecode: boolean?, raw: boolean? }?
---@return string|{ name: string, modules: { name: string, code: string }[] }
local function bundlePackage(package, opts)
	opts = opts or {}
	local useBytecode = opts.bytecode or opts.raw
	local raw = opts.raw

	local files = {}
	local modulesDir = package:getModulesDir()

	for entry in fs.readdir(modulesDir) do
		local p = path.join(modulesDir, entry.name)
		if fs.isdir(p) then
			bundleDir(entry.name, p, files)
		elseif entry.name:match("%.lua$") then
			local content = fs.read(p)
			if content then
				local moduleName = entry.name:gsub("%.lua$", "")
				files[moduleName] = content
			end
		end
	end

	local mainName = package:getName()

	if raw then
		-- Raw bytecode table for sea.compile: each module's bytecode is kept
		-- separate so the C side can embed it as raw bytes and deserialize it
		-- lazily on first require(), instead of parsing/deserializing the whole
		-- module graph at startup.
		local modules = {}
		for moduleName, content in pairs(files) do
			modules[#modules + 1] = {
				name = moduleName,
				code = compileBytecode(content, moduleName)
			}
		end
		return { name = mainName, modules = modules }
	end

	local parts = {}
	for moduleName, content in pairs(files) do
		if useBytecode then
			content = escapeBytes(compileBytecode(content, moduleName))
		else
			content = escapeString(content)
		end

		if moduleName == mainName then
			-- Main entry: loaded eagerly so the final call can pass args through.
			parts[#parts + 1] = string.format(
				'package.preload["%s"] = load("%s", "@%s")',
				moduleName, content, moduleName
			)
		else
			-- Everything else: defer bytecode deserialization to first require(),
			-- so trivial commands (--version, help) don't pay for the whole
			-- module graph at startup. Forward the modname vararg that require
			-- passes to preload loaders: modules use (...), e.g. lde-core does
			-- package.loaded[(...)] = lde at the top.
			parts[#parts + 1] = string.format(
				'package.preload["%s"] = function(...) return load("%s", "@%s")(...) end',
				moduleName, content, moduleName
			)
		end
	end

	parts[#parts + 1] = string.format('return package.preload["%s"](...)', package:getName())

	local result = table.concat(parts, "\n") .. "\n"

	if useBytecode then
		result = compileBytecode(result, package:getName())
	end

	return result
end

return bundlePackage
