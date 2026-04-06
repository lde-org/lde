local rocked = require("rocked")
local sea = require("sea")
local lde = require("lde-core")

local fs = require("fs")
local env = require("env")
local http = require("http")
local path = require("path")
local process = require("process2")
local util = require("util")

---@param dir string?
---@param rockspecPath string? # Path to the rockspec file; if nil, scanned from dir
---@return lde.Package?, string?
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
		local cacheFile = path.join(lde.global.getRockspecCacheDir(), (rockspecPath:gsub("[^%w]", "_")))
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

	local pkg = setmetatable({ dir = dir }, lde.Package)

	local modules = {}
	local nativeModules = {}
	if spec.build then
		for modname, src in pairs(spec.build.modules or {}) do
			if type(src) == "string" then
				if path.extension(src) == "lua" then
					modules[modname] = src
				elseif path.extension(src) == "c" then
					nativeModules[modname] = { sources = { src } }
				else
					io.stderr:write("warning: " ..
						(spec.package or "?") ..
						": unrecognised source type for module '" .. modname .. "': " .. src .. "\n")
				end
			elseif type(src) == "table" and src.sources then
				nativeModules[modname] = src
			elseif type(src) == "table" then
				io.stderr:write("warning: " ..
					(spec.package or "?") .. ": module '" .. modname .. "' has no sources field, skipping\n")
			end
		end

		-- Merge platform-specific modules
		local platFallbacks = {
			darwin = { "macosx", "unix" },
			linux  = { "linux", "unix" },
			win32  = { "win32", "mingw32" }
		}
		local jitPlatform = jit.os == "Windows" and "win32" or jit.os == "OSX" and "darwin" or "linux"

		local platBuild
		for _, key in ipairs(platFallbacks[jitPlatform] or { jitPlatform }) do
			platBuild = spec.build.platforms and spec.build.platforms[key]
			if platBuild then break end
		end
		if spec.build.platforms and not platBuild then
			io.stderr:write("warning: " ..
				(spec.package or "?") .. ": no platform config for '" .. jitPlatform .. "'\n")
		end

		for modname, src in pairs(platBuild and platBuild.modules or {}) do
			if type(src) == "string" then
				if path.extension(src) == "lua" then
					modules[modname] = src
				else
					nativeModules[modname] = { sources = { src } }
				end
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

	local buildType = spec.build and spec.build.type or "builtin"

	local buildStamp = util.fnv1a(content)

	local function mkdirp(p)
		if fs.isdir(p) then return end
		mkdirp(path.dirname(p))
		fs.mkdir(p)
	end

	pkg.buildfn = function(_, outputDir)
		if not fs.isdir(outputDir) then fs.mkdir(outputDir) end

		local stampFile = path.join(outputDir, ".lde-built")
		if fs.exists(stampFile) and fs.read(stampFile) == buildStamp then
			return true
		end

		local modulesDir = path.dirname(outputDir)

		if buildType == "make" then
			local luajitPath = sea.getLuajitPath()
			local luajitInclude = path.join(luajitPath, "include")
			local makeVars = {
				"LUA_INCDIR=" .. luajitInclude,
				"LUA_LIBDIR=" .. path.join(luajitPath, "lib"),
				"LUALIB=libluajit.a",
				"CFLAGS=-fPIC",
				"LIBFLAG=-shared",
				"INST_LIBDIR=" .. modulesDir,
				"INST_LUADIR=" .. modulesDir
			}
			local buildTarget = spec.build.build_target or ""
			local installTarget = spec.build.install_target or "install"

			local buildArgs = {}
			for _, v in ipairs(makeVars) do buildArgs[#buildArgs + 1] = v end
			if buildTarget ~= "" then buildArgs[#buildArgs + 1] = buildTarget end

			local code, _, stderr = process.exec("make", buildArgs, { cwd = dir })
			if code ~= 0 then return nil, "make failed: " .. (stderr or "") end

			local installArgs = {}
			for _, v in ipairs(makeVars) do installArgs[#installArgs + 1] = v end
			installArgs[#installArgs + 1] = installTarget

			code, _, stderr = process.exec("make", installArgs, { cwd = dir })
			if code ~= 0 then return nil, "make install failed: " .. (stderr or "") end

			fs.write(stampFile, buildStamp)
			return true
		elseif buildType == "cmake" then
			local luajitPath = sea.getLuajitPath()
			local buildDir = path.join(dir, "build.lde")
			local installDir = path.join(dir, "install.lde")
			if not fs.isdir(buildDir) then fs.mkdir(buildDir) end
			if not fs.isdir(installDir) then fs.mkdir(installDir) end

			local configureArgs = {
				"-H.", "-B" .. buildDir,
				"-DLUA_BUILD_TYPE=System",
				"-DWITH_LUA_ENGINE=LuaJIT",
				"-DLUAJIT_INCLUDE_DIR=" .. path.join(luajitPath, "include"),
				"-DLUAJIT_LIBRARIES=" .. path.join(luajitPath, "lib", "libluajit.a"),
				"-DCMAKE_INSTALL_PREFIX=" .. installDir
			}
			for k, v in pairs(spec.build.build_variables or {}) do
				configureArgs[#configureArgs + 1] = "-D" .. k .. "=" .. v
			end

			local code, _, stderr = process.exec("cmake", configureArgs, { cwd = dir })
			if code ~= 0 then return nil, "cmake configure failed: " .. (stderr or "") end

			code, _, stderr = process.exec("cmake", { "--build", buildDir, "--config", "Release" }, { cwd = dir })
			if code ~= 0 then return nil, "cmake build failed: " .. (stderr or "") end

			code, _, stderr = process.exec("cmake", { "--build", buildDir, "--target", "install", "--config", "Release" },
				{ cwd = dir })
			if code ~= 0 then return nil, "cmake install failed: " .. (stderr or "") end

			local soExt = jit.os == "OSX" and "**.dylib" or "**.so"
			for _, rel in ipairs(fs.scan(installDir, soExt)) do
				fs.copy(path.join(installDir, rel), path.join(modulesDir, path.basename(rel)))
			end

			fs.write(stampFile, buildStamp)
			return true
		elseif buildType == "builtin" then
			for modname, src in pairs(modules) do
				local modPath = modname:gsub("%.", path.separator)
				local srcBase = path.basename(src)
				local destAbs
				if srcBase == "init.lua" then
					-- source is an init.lua: install as modPath/init.lua
					-- but if modname ends in .init (e.g. "system.init"), strip that segment
					local dirPath = modname:match("^(.+)%.init$")
					if dirPath then
						destAbs = path.join(modulesDir, dirPath:gsub("%.", path.separator), "init.lua")
					else
						destAbs = path.join(modulesDir, modPath, "init.lua")
					end
				else
					destAbs = path.join(modulesDir, modPath .. ".lua")
				end
				local destDir = path.dirname(destAbs)
				if not fs.isdir(destDir) then mkdirp(destDir) end
				fs.copy(path.join(dir, src), destAbs)
			end

			for modname, src in pairs(nativeModules) do
				local ext = jit.os == "OSX" and "dylib" or "so"
				local destAbs = path.join(modulesDir, modname:gsub("%.", path.separator) .. "." .. ext)
				local destDir = path.dirname(destAbs)
				if not fs.isdir(destDir) then mkdirp(destDir) end

				local srcFiles = {}
				for _, s in ipairs(src.sources) do
					srcFiles[#srcFiles + 1] = path.join(dir, s)
				end

				local gccArgs = { "-shared", "-fPIC", "-I" .. path.join(sea.getLuajitPath(), "include") }
				for _, s in ipairs(srcFiles) do gccArgs[#gccArgs + 1] = s end
				gccArgs[#gccArgs + 1] = "-o"
				gccArgs[#gccArgs + 1] = destAbs

				local code, _, stderr = process.exec("gcc", gccArgs)
				if code ~= 0 then
					return nil, "Failed to compile native module '" .. modname .. "': " .. (stderr or "")
				end
			end

			for k, v in pairs(binScripts) do
				local binName, binRelSrc = type(k) == "number" and v or k, v
				fs.copy(path.join(dir, binRelSrc), path.join(outputDir, binName))
			end

			fs.write(stampFile, buildStamp)
			return true
		else
			return nil, "unsupported build type: " .. buildType
		end -- builtin
	end

	pkg.readConfig = function()
		local deps = {}
		for _, depStr in ipairs(spec.dependencies or {}) do
			local name, rest = depStr:match("^([%w%-_]+)%s*(.*)")
			if name and name ~= "lua" then
				deps[name] = { luarocks = name, version = rest ~= "" and rest or nil }
			end
		end

		return lde.Package.Config.new({ name = spec.package, version = spec.version, bin = binEntry, dependencies = deps })
	end

	return pkg, nil
end

return openRockspec
