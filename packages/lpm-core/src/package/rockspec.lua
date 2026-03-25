local Package = require("lpm-core.package")
local Config = require("lpm-core.config")
local rocked = require("rocked")
local sea = require("sea")

local fs = require("fs")
local env = require("env")
local path = require("path")
local process = require("process")

---@param dir string?
---@param rockspecPath string? # Path to the rockspec file; if nil, scanned from dir
---@return lpm.Package?, string?
local function openRockspec(dir, rockspecPath)
	dir = dir or env.cwd()

	if not rockspecPath then
		if fs.isdir(dir) then
			for _, entry in ipairs(fs.scan(dir, "**.rockspec")) do
				rockspecPath = path.join(dir, entry)
				break
			end
		end
	elseif not path.isAbsolute(rockspecPath) then
		rockspecPath = path.join(dir, rockspecPath)
	end

	if not rockspecPath then
		return nil, "No rockspec found in directory: " .. dir
	end

	local content = fs.read(rockspecPath)
	if not content then
		return nil, "Could not read rockspec: " .. rockspecPath
	end

	local ok, spec = rocked.parse(content)
	if not ok then
		return nil, "Failed to parse rockspec: " .. (spec or rockspecPath)
	end ---@cast spec rocked.raw.Output

	local pkg = setmetatable({ dir = dir }, Package)

	local modules = {}
	local nativeModules = {}
	if spec.build then
		for modname, src in pairs(spec.build.modules or {}) do
			if type(src) == "string" then
				if src:match("%.lua$") then
					modules[modname] = src
				elseif src:match("%.c$") then
					nativeModules[modname] = { sources = { src } }
				end
			elseif type(src) == "table" and src.sources then
				nativeModules[modname] = src
			end
		end
		for modname, src in pairs((spec.build.install or {}).lua or {}) do
			modules[modname] = src
		end
		-- Merge platform-specific modules
		local platKey = process.platform == "darwin" and "macosx" or process.platform
		local platBuild = spec.build.platforms and spec.build.platforms[platKey]
		for modname, src in pairs(platBuild and platBuild.modules or {}) do
			if type(src) == "string" then
				nativeModules[modname] = { sources = { src } }
			elseif type(src) == "table" and src.sources then
				nativeModules[modname] = src
			end
		end
	end

	local entryModule = spec.package and spec.package:lower()
	local binScripts = (spec.build and spec.build.install and spec.build.install.bin) or {}
	-- Pick the first bin entry as the package entrypoint
	local binEntry, binSrc
	for k, v in pairs(binScripts) do
		binEntry, binSrc = k, v
		break
	end

	pkg.buildfn = function(_, outputDir)
		local modulesDir = path.dirname(outputDir)

		local resolved = {}
		for modname, src in pairs(modules) do
			local srcAbs = path.join(dir, src)
			local destRel = modname:gsub("%.", path.separator) .. ".lua"
			if path.join(modulesDir, destRel) == path.join(outputDir, "init.lua") then
				destRel = modname:gsub("%.", path.separator):gsub("init$", "__init") .. ".lua"
			end
			local destAbs = path.join(modulesDir, destRel)
			local destDir = path.dirname(destAbs)
			if not fs.isdir(destDir) then fs.mkdir(destDir) end
			fs.copy(srcAbs, destAbs)
			resolved[modname] = { destRel = destRel, destAbs = destAbs }
		end

		for modname, src in pairs(nativeModules) do
			local ext = process.platform == "darwin" and "dylib" or "so"
			local destRel = modname:gsub("%.", path.separator) .. "." .. ext
			local destAbs = path.join(modulesDir, destRel)
			local destDir = path.dirname(destAbs)
			if not fs.isdir(destDir) then fs.mkdir(destDir) end

			local srcFiles = {}
			for _, s in ipairs(src.sources) do
				srcFiles[#srcFiles + 1] = path.join(dir, s)
			end

			local gccArgs = { "-shared", "-fPIC", "-I" .. path.join(sea.getLuajitPath(), "include") }
			for _, s in ipairs(srcFiles) do gccArgs[#gccArgs + 1] = s end
			gccArgs[#gccArgs + 1] = "-o"
			gccArgs[#gccArgs + 1] = destAbs

			local ok, err = process.exec("gcc", gccArgs)
			if not ok then
				return nil, "Failed to compile native module '" .. modname .. "': " .. (err or "")
			end
		end

		local lines = {
			"local _dir = debug.getinfo(1,'S').source:sub(2):match('^(.*/)') or './'"
		}
		for modname, info in pairs(resolved) do
			table.insert(lines, string.format(
				"package.preload[%q] = package.preload[%q] or function() return dofile(_dir .. %q) end",
				modname, modname, "../" .. info.destRel
			))
		end
		if entryModule then
			local info = resolved[entryModule] or resolved[entryModule .. ".init"]
			if info then
				table.insert(lines, string.format("return dofile(_dir .. %q)", "../" .. info.destRel))
			elseif nativeModules[entryModule] then
				local ext = process.platform == "darwin" and "dylib" or "so"
				table.insert(lines, string.format(
					"return package.loadlib(_dir .. %q, %q)()",
					"../" .. entryModule:gsub("%.", path.separator) .. "." .. ext,
					"luaopen_" .. entryModule:gsub("%.", "_")
				))
			end
		end

		fs.write(path.join(outputDir, "init.lua"), table.concat(lines, "\n") .. "\n")

		-- Copy bin scripts into the output dir
		for binName, binRelSrc in pairs(binScripts) do
			local srcAbs = path.join(dir, binRelSrc)
			fs.copy(srcAbs, path.join(outputDir, binName))
		end

		return true
	end

	pkg.readConfig = function()
		local deps = {}
		for _, depStr in ipairs(spec.dependencies or {}) do
			local name, rest = depStr:match("^([%w%-_]+)%s*(.*)")
			if name and name ~= "lua" then
				deps[name] = { luarocks = name, version = rest ~= "" and rest or nil }
			end
		end
		return Config.new({ name = spec.package, version = spec.version, bin = binEntry, dependencies = deps })
	end

	return pkg, nil
end

return openRockspec
