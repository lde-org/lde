local rocked = require("rocked")
local sea = require("sea")
local lpm = require("lpm-core")

local fs = require("fs")
local env = require("env")
local http = require("http")
local path = require("path")
local process = require("process")
local util = require("util")

---@param dir string?
---@param rockspecPath string? # Path to the rockspec file; if nil, scanned from dir
---@return lpm.Package?, string?
local function openRockspec(dir, rockspecPath)
	dir = dir or env.cwd()

	local content
	if not rockspecPath then -- Search for a rockspec in the directory
		if fs.isdir(dir) then
			local iter = fs.readdir(dir)
			if iter then
				for entry in iter do
					if entry.type == "file" and entry.name:match("%.rockspec$") then
						rockspecPath = path.join(dir, entry.name)
						break
					end
				end
			end
		end
		if not rockspecPath then
			return nil, "No rockspec found in directory: " .. dir
		end

		content = fs.read(rockspecPath)
		if not content then
			return nil, "Could not read rockspec: " .. rockspecPath
		end
	elseif rockspecPath:match("^https?://") then -- Looks like a URL
		local cacheFile = path.join(lpm.global.getRockspecCacheDir(), (rockspecPath:gsub("[^%w]", "_")))
		if fs.exists(cacheFile) then
			content = fs.read(cacheFile)
		else
			local err
			content, err = http.get(rockspecPath)
			if not content then
				return nil, "Could not fetch rockspec: " .. rockspecPath .. ": " .. (err or "")
			end

			fs.write(cacheFile, content)
		end
	else -- Looks like a path
		if not path.isAbsolute(rockspecPath) then
			rockspecPath = path.join(dir, rockspecPath)
		end
		content = fs.read(rockspecPath)
		if not content then
			return nil, "Could not read rockspec: " .. rockspecPath
		end
	end ---@cast content -nil

	local ok, spec = rocked.parse(content)
	if not ok then
		return nil, "Failed to parse rockspec: " .. (spec or rockspecPath)
	end ---@cast spec rocked.raw.Output

	local pkg = setmetatable({ dir = dir }, lpm.Package)

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

	local binScripts = (spec.build and spec.build.install and spec.build.install.bin) or {}
	local binEntry
	for k, v in pairs(binScripts) do
		binEntry = type(k) == "number" and v or k
		break
	end

	local buildStamp = util.fnv1a(content)

	pkg.buildfn = function(_, outputDir)
		if not fs.isdir(outputDir) then fs.mkdir(outputDir) end

		local stampFile = path.join(outputDir, ".lpm-built")
		if fs.exists(stampFile) and fs.read(stampFile) == buildStamp then
			return true
		end

		local modulesDir = path.dirname(outputDir)

		for modname, src in pairs(modules) do
			local destAbs = path.join(modulesDir, modname:gsub("%.", path.separator) .. ".lua")
			local destDir = path.dirname(destAbs)
			if not fs.isdir(destDir) then fs.mkdir(destDir) end
			fs.copy(path.join(dir, src), destAbs)
		end

		for modname, src in pairs(nativeModules) do
			local ext = process.platform == "darwin" and "dylib" or "so"
			local destAbs = path.join(modulesDir, modname:gsub("%.", path.separator) .. "." .. ext)
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

		for k, v in pairs(binScripts) do
			local binName, binRelSrc = type(k) == "number" and v or k, v
			fs.copy(path.join(dir, binRelSrc), path.join(outputDir, binName))
		end

		fs.write(stampFile, buildStamp)
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

		return lpm.Config.new({ name = spec.package, version = spec.version, bin = binEntry, dependencies = deps })
	end

	return pkg, nil
end

return openRockspec
