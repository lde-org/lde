local ansi = require("ansi")
local fs = require("fs")
local path = require("path")

local lpm = require("lpm-core")

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

---@param args clap.Args
local function bundle(args)
	local useBytecode = args:flag("bytecode")
	local outFile = args:option("outfile")

	local pkg, err = lpm.Package.open()
	if not pkg then
		ansi.printf("{red}%s", err)
		return
	end

	if not outFile then
		outFile = path.join(pkg:getDir(), pkg:getName() .. ".lua")
	end

	pkg:build()
	pkg:installDependencies()

	local files = {}
	local modulesDir = pkg:getModulesDir()

	bundleDir(pkg:getName(), path.join(modulesDir, pkg:getName()), files)

	local lockfile = pkg:readLockfile()
	local deps = lockfile and lockfile:getDependencies() or pkg:getDependencies()
	for depName in pairs(deps) do
		bundleDir(depName, path.join(modulesDir, depName), files)
	end

	local parts = {}
	for moduleName, content in pairs(files) do
		if useBytecode then
			content = escapeBytes(compileBytecode(content, moduleName))
		else
			content = escapeString(content)
		end

		parts[#parts + 1] = string.format(
			'package.preload["%s"] = load("%s", "@%s")',
			moduleName, content, moduleName
		)
	end

	parts[#parts + 1] = string.format('return package.preload["%s"](...)', pkg:getName())

	local completeFile = table.concat(parts, "\n") .. "\n"

	if useBytecode then
		completeFile = compileBytecode(completeFile, pkg:getName())
	end

	fs.write(outFile, completeFile)
	ansi.printf("{green}Bundled to %s", outFile)
end

return bundle
