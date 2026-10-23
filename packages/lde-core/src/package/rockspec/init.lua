--- Rockspec packages: parse a *.rockspec into a lde.Package whose buildfn runs one
--- of LuaRocks' build backends (builtin/module/none, make, cmake, command, or a
--- custom luarocks-build-* backend).

const rocked = require("rocked")
const sea = require("sea")
const lde = require("lde-core")

const fs = require("fs")
local env = require("env")
local path = require("path")
const util = require("util")

const curl = util.lazy(|| -> require("curl-sys"))

const external = require("lde-core.package.rockspec.external")
const native = require("lde-core.package.rockspec.native")
const vars = require("lde-core.package.rockspec.vars")

---@class lde.rockspec.BuildContext
---@field dir string # rock source dir
---@field modulesDir string # <rock>/target
---@field outputDir string # <rock>/target/<name>
---@field stampFile string
---@field buildStamp string
---@field spec rocked.raw.Output
---@field buildType string
---@field luajitPath string
---@field stdVars table<string, string>
---@field extVars table<string, string>
---@field makePath fun(p: string): string
---@field subst fun(s: string): string
---@field toolchainEnv fun(): table<string, string>?
---@field exportFPic boolean
---@field modules table<string, string>
---@field nativeModules table<string, lde.rockspec.NativeModuleSpec>
---@field binScripts table<any, string>
---@field installLuaFiles table<any, string>
---@field installLibFiles table<any, string>

local rockspec = {}

---@param dir string?
---@param rockspecPath string? # Path to the rockspec file; if nil, scanned from dir
---@return lde.Package?, string?
local function openRockspec(dir, rockspecPath)
	dir = dir or env.cwd()
	if not dir then
		return nil, "Current working directory no longer exists (it may have been deleted)"
	end ---@cast dir -nil

	-- On Windows, returns an env table with the bundled toolchain's bin dir
	-- prepended to PATH so child processes (gcc, ar, ld, sh, make, etc.) resolve.
	---@return table<string, string>?
	local function toolchainEnv()
		const mingwBin = vars.ensureMingw()
		if not mingwBin then return nil end
		return { PATH = mingwBin .. ";" .. (env.var("PATH") or "") }
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
		const cacheFile = path.join(lde.global.getRockspecCacheDir(), (rockspecPath:gsub("[^%w]", "_")))
		if fs.exists(cacheFile) then
			content = fs.read(cacheFile)
		else
			const res, err = curl().get(rockspecPath)
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

	const ok, spec = rocked.parse(content)
	if not ok then
		return nil, "Failed to parse rockspec: " .. (spec or rockspecPath)
	end ---@cast spec rocked.raw.Output

	local pkg = setmetatable({ dir = dir }, lde.Package)
	pkg.isRockspec = true
	pkg.rockspecData = spec

	local modules = {}
	local nativeModules = {}
	const binScripts, installLuaFiles, installLibFiles = {}, {}, {}

	-- Only builtin/module builds interpret build.modules as module sources; other
	-- backends consume the table themselves (rust-mlua uses an array of crate
	-- names), so never warn about entries we don't understand.
	const buildType = spec.build?.type ?? "builtin"
	const interpretsModules = buildType == "builtin" or buildType == "module"

	if spec.build then
		for modname, src in pairs(spec.build.modules or {}) do
			if type(src) == "string" then
				if path.extension(src) == "lua" then
					modules[modname] = src
				elseif path.extension(src) == "c" then
					nativeModules[modname] = { sources = { src } }
				elseif lde.isVerbose and interpretsModules then
					io.stderr:write("warning: " ..
						(spec.package or "?") ..
						": unrecognised source type for module '" .. modname .. "': " .. src .. "\n")
				end
			elseif type(src) == "table" and src.sources then ---@cast src rocked.raw.NativeSource
				nativeModules[modname] = native.normalizeModule(src, spec.build)
			elseif type(src) == "table" and (src --[[@as table]])[1] then
				nativeModules[modname] = native.normalizeModule({ sources = src }, spec.build)
			elseif type(src) == "table" and lde.isVerbose and interpretsModules then
				io.stderr:write("warning: " ..
					(spec.package or "?") .. ": module '" .. modname .. "' has no sources field, skipping\n")
			end
		end

		const platFallbacks = {
			darwin = { "macosx", "unix" },
			linux  = { "linux", "unix" },
			win32  = { "win32", "mingw32", "windows" }
		}
		const jitPlatform = jit.os == "Windows" ? "win32" : jit.os == "OSX" ? "darwin" : "linux"

		local platBuild
		for _, key in ipairs(platFallbacks[jitPlatform] or { jitPlatform }) do
			platBuild = spec.build.platforms?.[key]
			if platBuild then break end
		end

		-- The command backend runs the commands in ctx.spec.build, so a platform
		-- override (e.g. a Windows-only install command) must land in the base
		-- build table.
		if platBuild then
			const platCommands = platBuild --[[@as { build_command: string?, install_command: string? }]]
			if platCommands.build_command then spec.build.build_command = platCommands.build_command end
			if platCommands.install_command then spec.build.install_command = platCommands.install_command end
		end

		-- No platform entry means the base build table applies as-is: a partial
		-- platforms table (yuescript's windows-only install override) is fine.
		const platformModules = platBuild?.modules ?? {} ---@cast platformModules table<string, rocked.raw.BuildSource>
		for modname, src in pairs(platformModules) do
			if type(src) == "string" then
				if path.extension(src) == "lua" then
					modules[modname] = src
				else
					nativeModules[modname] = { sources = { src } }
				end
			elseif type(src) == "table" and src.sources then
				nativeModules[modname] = native.normalizeModule(src, platBuild)
			end
		end

		-- Platform build tables (e.g. platforms.unix) merge over the base build;
		-- LuaSec declares its install.lua only there.
		if spec.build.install then
			for k, v in pairs(spec.build.install.bin or {}) do binScripts[k] = v end
			for k, v in pairs(spec.build.install.lua or {}) do installLuaFiles[k] = v end
			for k, v in pairs(spec.build.install.lib or {}) do installLibFiles[k] = v end
		end
		if platBuild and platBuild.install then
			for k, v in pairs(platBuild.install.bin or {}) do binScripts[k] = v end
			for k, v in pairs(platBuild.install.lua or {}) do installLuaFiles[k] = v end
			for k, v in pairs(platBuild.install.lib or {}) do installLibFiles[k] = v end
		end
	end

	local binEntry
	const bk, bv = next(binScripts)
	if bk then binEntry = type(bk) == "number" and path.basename(bv --[[@as string]]) or bk end

	-- LuaRocks' builtin backend autodetects modules when a rockspec (format 3.0+)
	-- declares none.
	if next(modules) == nil and next(nativeModules) == nil
		and (buildType == "builtin" or buildType == "module") then
		local autoLua, autoNative = native.autodetectModules(dir, spec.package or "")
		modules, nativeModules = autoLua, autoNative
	end

	-- Whether this package's build can read dependency build outputs: the install
	-- build loop uses it to decide if a pending native compile of a dependency
	-- must finish first.
	pkg.hasBuildDeps = buildType ~= "builtin" and buildType ~= "module" and buildType ~= "none"
		or next(nativeModules) ~= nil

	-- The stamp covers the rockspec text, the build-logic version, the compile
	-- target, and the rock's own sources: the rockspec text alone does not change
	-- when a user edits src/, and serving stale build output on the next `lde
	-- run`/`lde test` is a silent trap.
	--
	-- The running lde version cannot be used here: the shared tar cache is built
	-- by processes whose project may or may not have lde.version on its package
	-- path (the monorepo runner starts one per package), so the same rock got two
	-- different stamps and every process rebuilt it under the last one's reader.
	-- Bump this when the build output layout or the backend semantics change.
	const BUILD_STAMP_VERSION = 2
	local sourceHash = {} ---@type string[]
	---@param rel string # package-relative path of a file or directory
	local function stampSource(rel)
		if rel:match("^https?://") then return end -- remote sources are fetched per build
		const p = path.isAbsolute(rel) ? rel : path.join(dir, rel)
		if fs.isdir(p) then
			for _, f in ipairs(fs.scan(p, "**")) do
				local c = fs.read(path.join(p, f))
				if c then sourceHash[#sourceHash + 1] = util.hash(c) end
			end
		else
			local c = fs.read(p)
			if c then sourceHash[#sourceHash + 1] = util.hash(c) end
		end
	end
	for _, src in pairs(modules) do stampSource(src) end
	for _, m in pairs(nativeModules) do
		local srcs = m.sources
		if type(srcs) == "string" then srcs = { srcs } end ---@cast srcs -string
		for _, s in ipairs(srcs or {}) do stampSource(s) end
	end
	for _, src in pairs(binScripts) do stampSource(src) end
	for _, src in pairs(installLuaFiles) do stampSource(src) end
	for _, src in pairs(installLibFiles) do stampSource(src) end
	for _, copyDir in ipairs(spec.build and spec.build.copy_directories or {}) do stampSource(copyDir) end
	table.sort(sourceHash)
	const buildStamp = util.hash(content .. "\n" .. tostring(BUILD_STAMP_VERSION)
		.. "\n" .. tostring(jit.version) .. "\n" .. lde.global.getTargetKey()
		.. "\n" .. table.concat(sourceHash, ","))

	---@param outputDir string
	---@return boolean?, string?, lde.install.DeferredBuild?
	pkg.buildfn = function(_, outputDir)
		if not fs.isdir(outputDir) then fs.mkdirAll(outputDir) end

		const stampFile = path.join(outputDir, ".lde-built")
		if fs.exists(stampFile) and fs.read(stampFile) == buildStamp then
			return true
		end

		-- Rebuilding (new rockspec/source): start from a clean output dir, exactly
		-- once, here, rather than on every pkg:build() call. A concurrent loader
		-- keeps the tree it resolved, and a second build only re-enters after the
		-- new stamp is written.
		if fs.isdir(outputDir) then
			fs.rmdir(outputDir)
			fs.mkdirAll(outputDir)
		end

		local extVars = {}
		if spec.external_dependencies then
			const extErr = external.resolve(spec.external_dependencies, extVars, spec.package or "?")
			if extErr then return nil, extErr end
		end

		const modulesDir = path.dirname(outputDir)
		const makePath = vars.makePathFn()
		const luajitPath = sea.getLuajitPath(nil, lde.global.getTarget())
		const stdVars = vars.standard(modulesDir, luajitPath, makePath)
		for k, v in pairs(extVars) do stdVars[k] = v end

		const exportFPic = vars.exportFPic()
		-- Always exported, empty on Windows: a build command may read CFLAGS
		-- unconditionally (LuaRocks exports it the same way).
		stdVars.CFLAGS = exportFPic and "-fPIC" or ""

		---@type lde.rockspec.BuildContext
		const ctx = {
			dir = dir,
			modulesDir = modulesDir,
			outputDir = outputDir,
			stampFile = stampFile,
			buildStamp = buildStamp,
			spec = spec,
			buildType = buildType,
			luajitPath = luajitPath,
			stdVars = stdVars,
			extVars = extVars,
			makePath = makePath,
			subst = vars.substFn(stdVars),
			toolchainEnv = toolchainEnv,
			exportFPic = exportFPic,
			modules = modules,
			nativeModules = nativeModules,
			binScripts = binScripts,
			installLuaFiles = installLuaFiles,
			installLibFiles = installLibFiles,
		}

		if buildType == "make" then
			return require("lde-core.package.rockspec.backend.make").run(ctx)
		elseif buildType == "cmake" then
			return require("lde-core.package.rockspec.backend.cmake").run(ctx)
		elseif buildType == "builtin" or buildType == "module" or buildType == "none" then
			return require("lde-core.package.rockspec.backend.builtin").run(ctx)
		elseif buildType == "command" then
			return require("lde-core.package.rockspec.backend.command").run(ctx)
		end

		-- Custom build backend (e.g. rust-mlua): LuaRocks loads a module named
		-- luarocks.build.<type> from the luarocks-build-<type> rock (installed via
		-- build_dependencies) and calls driver.run().
		const prevDir = env.cwd()
		env.chdir(dir)
		const r1, r2, r3 = pcall(rocked.runBackend, buildType, {
			name = spec.package,
			version = spec.version,
			build = spec.build,
			variables = stdVars,
		}, {
			cwd = dir,
			libDir = modulesDir,
			packagePath = path.join(modulesDir, "?.lua") .. ";" .. path.join(modulesDir, "?", "init.lua"),
			cpath = path.join(modulesDir, "?.so") .. ";" .. path.join(modulesDir, "?.dll") .. ";" .. path.join(modulesDir, "?.dylib"),
		})
		env.chdir(prevDir)
		if not r1 then
			return nil, "Build error: " .. tostring(r2)
		end
		if not r2 then
			return nil, "Build error: " .. (r3 or "unknown error")
		end

		fs.write(stampFile, buildStamp)
		return true
	end

	pkg.readConfig = function()
		local deps = {}
		lde.util.addRockspecDeps(deps, spec.dependencies or {})
		-- Build backends (e.g. luarocks-build-rust-mlua) install alongside runtime
		-- deps so their modules resolve at build time.
		lde.util.addRockspecDeps(deps, spec.build_dependencies or {})

		local resolvedBin = binEntry
		if not resolvedBin and (buildType == "make" or buildType == "cmake") then
			-- make/cmake installs are promoted into the package target dir; take the
			-- first entry there that could be a program. A library's target dir
			-- holds files like lgi's class.lua / corelgilua51.so, and picking one of
			-- those either loaded a native module as Lua source or announced that a
			-- library was runnable.
			const targetDir = path.join(dir, "target", spec.package or "")
			if fs.isdir(targetDir) then
				local iter = fs.readdir(targetDir)
				if iter then
					for entry in iter do
						if entry.type == "file"
							and not entry.name:match("^%.")
							and not native.isModuleFile(entry.name) then
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
			dependencies = deps
		})
	end

	return pkg, nil
end

rockspec.open = openRockspec
rockspec.nativeGccArgs = native.gccArgs
rockspec.normalizeNativeModule = native.normalizeModule
rockspec.resolveExternalDeps = external.resolve

return rockspec
