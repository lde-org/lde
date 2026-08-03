local rocked = require("rocked")
local sea = require("sea")
local lde = require("lde-core")

local fs = require("fs")
local env = require("env")
local path = require("path")
local process = require("process")
local util = require("util")
local curl = require("curl-sys")

---@param dir string?
---@param rockspecPath string? # Path to the rockspec file; if nil, scanned from dir
---@return lde.Package?, string?
local function openRockspec(dir, rockspecPath)
	dir = dir or env.cwd()

	-- On Windows, returns an env table with the bundled toolchain's bin dir
	-- prepended to PATH so child processes (gcc, ar, ld, sh, make, etc.)
	-- resolve. Returns nil on non-Windows or when PATH already has it.
	---@return table?
	local function toolchainEnv()
		if jit.os ~= "Windows" then return nil end
		local mingwBin = path.join(lde.global.getMingwDir(), "bin")
		local curPath = env.var("PATH") or ""
		if curPath:find(mingwBin, 1, true) then return nil end
		return { PATH = mingwBin .. ";" .. curPath }
	end

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
			local res, err = curl.get(rockspecPath)
			if not res then
				return nil, "Could not fetch rockspec: " .. rockspecPath .. ": " .. (err or "")
			end

			content = res.body
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
	local binScripts, installLuaFiles = {}, {}

	-- LuaRocks accepts a plain string or a list for a native module's
	-- sources/libraries/libdirs/incdirs/defines (lzlib uses `libraries = "z"`),
	-- and a build-level default (build.libraries etc.) applies to every module
	-- unless the module overrides it. Normalize both into per-module lists.
	local function normalizeNative(src, buildTable)
		if type(src.sources) == "string" then src.sources = { src.sources } end
		for _, f in ipairs({ "libraries", "libdirs", "incdirs", "defines" }) do
			if type(src[f]) == "string" then
				src[f] = { src[f] }
			elseif src[f] == nil and buildTable and buildTable[f] then
				src[f] = type(buildTable[f]) == "string" and { buildTable[f] } or buildTable[f]
			end
		end
		return src
	end

	if spec.build then
		for modname, src in pairs(spec.build.modules or {}) do
			if type(src) == "string" then
				if path.extension(src) == "lua" then
					modules[modname] = src
				elseif path.extension(src) == "c" then
					nativeModules[modname] = { sources = { src } }
				elseif lde.verbose then
					io.stderr:write("warning: " ..
						(spec.package or "?") ..
						": unrecognised source type for module '" .. modname .. "': " .. src .. "\n")
				end
			elseif type(src) == "table" and src.sources then
				nativeModules[modname] = normalizeNative(src, spec.build)
			elseif type(src) == "table" and src[1] then
				nativeModules[modname] = normalizeNative({ sources = src }, spec.build)
			elseif type(src) == "table" and lde.verbose then
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

		if spec.build.platforms and not platBuild and lde.verbose then
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
				nativeModules[modname] = normalizeNative(src, platBuild)
			end
		end

		-- Platform build tables (e.g. platforms.unix) merge over the base build;
		-- LuaSec declares its install.lua only there.
		if spec.build.install then
			for k, v in pairs(spec.build.install.bin or {}) do binScripts[k] = v end
			for k, v in pairs(spec.build.install.lua or {}) do installLuaFiles[k] = v end
		end
		if platBuild and platBuild.install then
			for k, v in pairs(platBuild.install.bin or {}) do binScripts[k] = v end
			for k, v in pairs(platBuild.install.lua or {}) do installLuaFiles[k] = v end
		end
	end

	local binEntry
	local bk, bv = next(binScripts)
	if bk then binEntry = type(bk) == "number" and path.basename(bv) or bk end

	local buildType = spec.build and spec.build.type or "builtin"

	-- Include the lde runtime version in the stamp so build outputs are
	-- rebuilt when the binary is upgraded (build logic may have changed, e.g.
	-- module layout rules).
	local buildStamp = util.fnv1a(content .. "\n" .. tostring(lde.global.currentVersion))

	pkg.buildfn = function(_, outputDir)
		if not fs.isdir(outputDir) then fs.mkdirAll(outputDir) end

		local stampFile = path.join(outputDir, ".lde-built")
		if fs.exists(stampFile) and fs.read(stampFile) == buildStamp then
			return true
		end

		local modulesDir = path.dirname(outputDir)

		-- On Windows, pass forward-slash paths to make: sh (busybox) eats
		-- backslashes in unquoted make recipes, and Windows tools accept '/'
		-- in paths.
		local function makePath(p)
			if jit.os ~= "Windows" then return p end
			return (p:gsub("\\", "/"))
		end

		if buildType == "make" then
			lde.global.ensureMingw()
			local makeBin = lde.global.getMakeBin()
			if not process.exec(makeBin, { "--version" }) then
				return nil,
					"Package '" .. (spec.package or "?") .. "' requires 'make' to build, but it was not found." ..
					" Install make (e.g. build-essential on Debian/Ubuntu, Xcode Command Line Tools on macOS)."
			end

			local makeEnv = toolchainEnv()

			local luajitPath = sea.getLuajitPath()
			local stdVars = {
				LUA_INCDIR  = makePath(path.join(luajitPath, "include")),
				LUA_LIBDIR  = makePath(path.join(luajitPath, "lib")),
				LUALIB      = "libluajit.a",
				CFLAGS      = "-fPIC",
				-- Rocks that auto-detect the Lua toolchain (cqueues' luapath)
				-- scan CPPFLAGS for -I dirs; without this they fall back to the
				-- system Lua headers (e.g. 5.4) and link against APIs LuaJIT
				-- doesn't export (lua_rawgetp).
				CPPFLAGS    = makePath("-I" .. path.join(luajitPath, "include")),
				LIBFLAG     = "-shared",
				INST_LIBDIR = makePath(modulesDir),
				INST_LUADIR = makePath(modulesDir),
				LUADIR      = makePath(modulesDir),
				LIBDIR      = makePath(modulesDir),
				PREFIX      = makePath(modulesDir),
				LUA         = makePath(env.execPath())
			}

			local function subst(s)
				return (s:gsub("%$%(([%w_]+)%)", function(k) return stdVars[k] or "" end))
			end

			local function buildVarList(extraVars)
				local args = {}
				for k, v in pairs(stdVars) do args[#args + 1] = k .. "=" .. v end
				for k, v in pairs(extraVars or {}) do
					args[#args + 1] = k .. "=" .. subst(v)
				end
				return args
			end

			local buildTarget = spec.build.build_target or ""
			local installTarget = spec.build.install_target or "install"

			local buildArgs = buildVarList(spec.build.variables)
			if buildTarget ~= "" then buildArgs[#buildArgs + 1] = buildTarget end

			local code, _, stderr = process.exec(makeBin, buildArgs, { cwd = dir, env = makeEnv })
			if code ~= 0 then
				local msg = (stderr ~= "" and stderr) or ("exited with code " .. code)
				return nil, "make failed: " .. msg
			end

			local installArgs = buildVarList(spec.build.install_variables)
			installArgs[#installArgs + 1] = installTarget

			code, _, stderr = process.exec(makeBin, installArgs, { cwd = dir, env = makeEnv })
			if code ~= 0 then
				local msg = (stderr ~= "" and stderr) or ("exited with code " .. code)
				return nil, "make install failed: " .. msg
			end

			-- Promote any binaries installed to modulesDir/bin/ into outputDir
			local binDir = path.join(modulesDir, "bin")
			if fs.isdir(binDir) then
				local iter = fs.readdir(binDir)
				if iter then
					for entry in iter do
						if entry.type == "file" then
							fs.copy(path.join(binDir, entry.name), path.join(outputDir, entry.name))
						end
					end
				end
			end

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
		elseif buildType == "builtin" or buildType == "module" or buildType == "none" then
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
				if not fs.isdir(destDir) then fs.mkdirAll(destDir) end
				fs.copy(path.join(dir, src), destAbs)
			end

			for modname, src in pairs(nativeModules) do
				-- LuaJIT uses .so on macOS too (its default cpath is ?.so), and
				-- rockspec build systems like luke hardcode .so in their install
				-- phase, so build with .so rather than .dylib.
				local ext = jit.os == "Windows" and "dll" or "so"
				local destAbs = path.join(modulesDir, modname:gsub("%.", path.separator) .. "." .. ext)
				local destDir = path.dirname(destAbs)
				if not fs.isdir(destDir) then fs.mkdirAll(destDir) end

				local srcFiles = {}
				for _, s in ipairs(src.sources) do
					srcFiles[#srcFiles + 1] = path.join(dir, s)
				end

				lde.global.ensureMingw()
				local ljPath = sea.getLuajitPath()
				local gccArgs = { "-shared", "-fPIC", "-DLUAJIT_VERSION=LuaJIT 2.1.0-beta3", "-DLUA_VERSION_NUM=501",
					"-I" .. path.join(ljPath, "include") }
				for _, d in ipairs(src.defines or {}) do gccArgs[#gccArgs + 1] = "-D" .. d end
				if jit.os == "Windows" then
					-- compat-5.3 (bundled by rocks like bit32) selects strerror_r when
					-- _XOPEN_SOURCE >= 600 (which lprefix.h defines), but UCRT only
					-- provides strerror_s — force the strerror_s branch.
					gccArgs[#gccArgs + 1] = "-DCOMPAT53_HAVE_STRERROR_R=0"
					gccArgs[#gccArgs + 1] = "-DCOMPAT53_HAVE_STRERROR_S=1"
				end
				-- Rockspec `incdirs` entries: absolute, relative to the package
				-- dir, or $(VAR) placeholders resolved from the rock's standard
				-- variables (unknown vars are skipped). LuaSec needs this for its
				-- bundled src/luasocket headers.
				local incVars = {
					LUA_INCDIR = path.join(ljPath, "include"),
					LUA_LIBDIR = path.join(ljPath, "lib"),
					PREFIX = modulesDir,
					LUADIR = modulesDir,
					LIBDIR = modulesDir,
				}
				for _, inc in ipairs(src.incdirs or {}) do
					local resolved = (inc:gsub("%$%(([%w_]+)%)", function(k) return incVars[k] or "" end))
					if resolved ~= "" and not resolved:find("$", 1, true) then
						local incPath = path.isAbsolute(resolved) and resolved or path.join(dir, resolved)
						gccArgs[#gccArgs + 1] = "-I" .. makePath(incPath)
					end
				end
				for _, s in ipairs(srcFiles) do gccArgs[#gccArgs + 1] = s end
				gccArgs[#gccArgs + 1] = "-o"
				gccArgs[#gccArgs + 1] = destAbs
				gccArgs[#gccArgs + 1] = "-L" .. path.join(ljPath, "lib")
				for _, d in ipairs(src.libdirs or {}) do
					local resolved = (d:gsub("%$%(([%w_]+)%)", function(k) return incVars[k] or "" end))
					if resolved ~= "" and not resolved:find("$", 1, true) then
						gccArgs[#gccArgs + 1] = "-L" .. makePath(resolved)
					end
				end
				if jit.os == "Windows" then gccArgs[#gccArgs + 1] = "-lluajit" end
				if jit.os == "OSX" then
					gccArgs[#gccArgs + 1] = "-undefined"; gccArgs[#gccArgs + 1] = "dynamic_lookup"
				end
				for _, l in ipairs(src.libraries or {}) do gccArgs[#gccArgs + 1] = "-l" .. l end

				local code, _, stderr = process.exec(lde.global.getCCBin(), gccArgs, { env = toolchainEnv() })
				if code ~= 0 then
					local msg = (stderr ~= "" and stderr) or ("exited with code " .. code)
					return nil, "Failed to compile native module '" .. modname .. "': " .. msg
				end
			end

			for k, v in pairs(binScripts) do
				local binName = type(k) == "number" and path.basename(v) or k
				local binDest = path.join(outputDir, binName)
				local binDestDir = path.dirname(binDest)
				if not fs.isdir(binDestDir) then fs.mkdirAll(binDestDir) end
				fs.copy(path.join(dir, v), binDest)
			end

			for modname, src in pairs(installLuaFiles) do
				if not src:match("%.lua$") then goto continue_install_lua end
				if type(modname) == "number" then
					-- LuaRocks semantics: a numeric key installs the file under its
					-- own basename (e.g. "src/ssl.lua" becomes module "ssl").
					modname = path.basename(src):gsub("%.lua$", "")
				end
				local modPath = modname:gsub("%.", path.separator)
				local destAbs = path.join(modulesDir, modPath .. ".lua")
				local destDir = path.dirname(destAbs)
				if not fs.isdir(destDir) then fs.mkdirAll(destDir) end
				fs.copy(path.join(dir, src), destAbs)
				::continue_install_lua::
			end

			-- copy_directories: ship non-module assets (e.g. luacov's HTML
			-- reporter static files) preserving their relative layout.
			for _, copyDir in ipairs(spec.build.copy_directories or {}) do
				local srcAbs = path.join(dir, copyDir)
				local destAbs = path.join(modulesDir, copyDir)
				if fs.isdir(srcAbs) then
					fs.mkdirAll(destAbs)
					fs.copy(srcAbs, destAbs)
				end
			end

			fs.write(stampFile, buildStamp)
			return true
		elseif buildType == "command" then
			local luajitPath = sea.getLuajitPath()
			local ldeBin = env.execPath()
			local vars = {
				LUA           = ldeBin,
				LUA_INCDIR    = path.join(luajitPath, "include"),
				LUA_LIBDIR    = path.join(luajitPath, "lib"),
				LIBDIR        = modulesDir,
				LUADIR        = modulesDir,
				PREFIX        = modulesDir,
				CC            = lde.global.getCCBin(),
				LD            = lde.global.getCCBin(),
				MAKE          = lde.global.getMakeBin(),
				CFLAGS        = "-fPIC",
				LIBFLAG       = jit.os == "OSX" and "-shared -undefined dynamic_lookup" or "-shared",
				-- LuaJIT modules are .so on every platform; rockspecs that pass
				-- $(LIB_EXTENSION) to their build (e.g. luaposix's luke) assume .so
				-- in their install phase, so .dylib here would leave built modules
				-- uninstallable on macOS.
				LIB_EXTENSION = jit.os == "Windows" and "dll" or "so",
				OBJ_EXTENSION = "o"
			}

			local function subst(cmd)
				return (cmd:gsub("%$%(([%w_]+)%)", function(k) return vars[k] or "" end))
			end

			local function shellSplit(cmd)
				local args = {}
				local i = 1
				while i <= #cmd do
					while i <= #cmd and cmd:sub(i, i) == " " do i = i + 1 end
					if i > #cmd then break end
					local token = ""
					while i <= #cmd and cmd:sub(i, i) ~= " " do
						local c = cmd:sub(i, i)
						if c == '"' then
							i = i + 1
							while i <= #cmd and cmd:sub(i, i) ~= '"' do
								token = token .. cmd:sub(i, i)
								i = i + 1
							end
							if i <= #cmd then i = i + 1 end -- skip closing quote
						else
							token = token .. c
							i = i + 1
						end
					end
					args[#args + 1] = token
				end
				return args
			end

			local function execCmd(cmdStr)
				if not cmdStr or cmdStr == "" then return true end
				local argv = shellSplit(subst(cmdStr))
				local bin = table.remove(argv, 1)
				-- If bin is the lde binary, inject --lua so it runs the next arg as a plain script
				if bin == ldeBin then
					table.insert(argv, 1, "--lua")
				end
				local code, _, stderr = process.exec(bin, argv, { cwd = dir, env = toolchainEnv() })
				if code ~= 0 then
					local msg = (stderr ~= "" and stderr) or ("exited with code " .. code)
					return nil, msg
				end
				return true
			end

			local cmdOk, cmdErr = execCmd(spec.build.build_command)
			if not cmdOk then return nil, "build_command failed: " .. (cmdErr or "(no output)") end

			cmdOk, cmdErr = execCmd(spec.build.install_command)
			if not cmdOk then return nil, "install_command failed: " .. (cmdErr or "(no output)") end

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
			if name and name ~= "lua" and name ~= "luajit" then
				deps[name] = { luarocks = name, version = rest ~= "" and rest or nil }
			end
		end

		local resolvedBin = binEntry
		if not resolvedBin and (buildType == "make" or buildType == "cmake") then
			-- Binaries from make/cmake installs are promoted into the package target dir
			local targetDir = path.join(dir, "target", spec.package or "")
			if fs.isdir(targetDir) then
				local iter = fs.readdir(targetDir)
				if iter then
					for entry in iter do
						if entry.type == "file" and entry.name ~= ".lde-built" then
							resolvedBin = entry.name
							break
						end
					end
				end
			end
		end

		return lde.Package.Config.new({
			name = spec.package,
			version = spec.version,
			bin = resolvedBin,
			dependencies =
				deps
		})
	end

	return pkg, nil
end

return openRockspec
