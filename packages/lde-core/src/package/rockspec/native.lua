--- Native (C) module handling: spec normalization, module autodetection, and the
--- gcc/clang argument list for one module.

const fs = require("fs")
local path = require("path")

const lde = require("lde-core")

local native = {}

--- Teal sources kept next to a rock's compiled modules so `tl check -I target`
--- can resolve the rock's module types.
native.TL_SOURCE_SUFFIXES = { "tl", "d.tl" }

--- Whether `name` is a module source rather than a runnable entry point.
---@param name string
function native.isModuleFile(name)
	return name:match("%.lua$") ~= nil
		or name:match("%.tl$") ~= nil
		or name:match("%.moon$") ~= nil
		or name:match("%.so$") ~= nil
		or name:match("%.dylib$") ~= nil
		or name:match("%.dll$") ~= nil
end

--- LuaRocks accepts a plain string or a list for a native module's
--- sources/libraries/libdirs/incdirs/defines (lzlib uses `libraries = "z"`), and a
--- build-level default applies to every module unless the module overrides it.
---@class lde.rockspec.NativeModuleSpec
---@field sources string|string[]
---@field libraries string|string[]?
---@field libdirs string|string[]?
---@field incdirs string|string[]?
---@field defines string|string[]?

---@class lde.rockspec.NormalizedNativeModule
---@field sources string[]
---@field libraries string[]?
---@field libdirs string[]?
---@field incdirs string[]?
---@field defines string[]?

---@param src table # NativeModuleSpec or rocked.raw.NativeSource (same shape)
---@param buildTable table?
function native.normalizeModule(src, buildTable)
	local sources = src.sources
	if type(sources) == "string" then
		src.sources = { sources }
	end
	for _, f in ipairs({ "libraries", "libdirs", "incdirs", "defines" }) do
		const value = src[f]
		if type(value) == "string" then
			src[f] = { value }
		elseif value == nil and buildTable then
			const fallback = buildTable[f]
			if fallback ~= nil then
				src[f] = type(fallback) == "string" and { fallback } or fallback
			end
		end
	end
	return src
end

--- LuaRocks' builtin backend autodetects modules when a rockspec (format 3.0+)
--- declares none: every .lua/.c file under the source root becomes a module named by
--- its path with a leading src/, lua/ or lib/ stripped. Used by rocks such as
--- luarocks-build-rust-mlua that ship their backend as a bare source tree.
---@param pkgDir string
---@param packageName string
---@return table<string, string> luaModules
---@return table<string, lde.rockspec.NativeModuleSpec> nativeModules
function native.autodetectModules(pkgDir, packageName)
	local luaModules, nativeModules = {}, {}
	local base = pkgDir
	for _, prefix in ipairs({ "src", "lua", "lib" }) do
		if fs.isdir(path.join(pkgDir, prefix)) then
			base = path.join(pkgDir, prefix)
			break
		end
	end

	-- Stored module paths are relative to the package root.
	const basePrefix = base ~= pkgDir
		and (path.relative(pkgDir, base):gsub("\\", "/") .. "/")
		or ""

	for _, rel in ipairs(fs.scan(base, "**")) do
		const first = rel:match("^([^/\\]+)")
		if first == "target" or first == ".git" or first == "build.luarocks" or first == "install.lde" then
			goto continue
		end
		local ext = path.extension(rel)
		if ext == "lua" or ext == "c" then
			local modName = rel:gsub("\\", "/"):gsub("%." .. ext .. "$", ""):gsub("/", ".")
			modName = modName:gsub("%.init$", "")
			if modName == "" then modName = packageName end
			const srcPath = basePrefix .. rel
			const isInit = rel:match("[/\\]init%.lua$") or rel == "init.lua"
			-- x.lua wins over x/init.lua, mirroring require()'s search order.
			if ext == "lua" then
				if not luaModules[modName] or not isInit then
					luaModules[modName] = srcPath
				end
			else
				if not nativeModules[modName] or not isInit then
					nativeModules[modName] = { sources = { srcPath } }
				end
			end
		end
		::continue::
	end
	return luaModules, nativeModules
end

---@class lde.rockspec.NativeGccContext
---@field packageDir string
---@field modulesDir string
---@field luajitPath string
---@field destAbs string
---@field jitOS string
---@field makePath? fun(path: string): string
---@field targetFlag? string # clang -target flag, prepended when cross-compiling
---@field extVars? table<string, string> # resolved rockspec external_dependencies

---@param ctx lde.rockspec.NativeGccContext
local function isWindowsBuild(ctx)
	const target = ctx.targetFlag or lde.global.getTargetTriple()
	return target ~= nil and target:lower():find("windows", 1, true) ~= nil
end

---@param ctx lde.rockspec.NativeGccContext
local function shouldUseFPIC(ctx)
	const hostOS = ctx.jitOS or jit.os
	return hostOS ~= "Windows" and not isWindowsBuild(ctx)
end

--- Pure: builds the compiler argument list for one native module from its
--- normalized spec, so flag construction is unit-testable without a toolchain.
---@param src lde.rockspec.NativeModuleSpec | lde.rockspec.NormalizedNativeModule
---@param ctx lde.rockspec.NativeGccContext
---@return string[]
function native.gccArgs(src, ctx)
	local jitOS = ctx.jitOS or jit.os
	local ljPath = ctx.luajitPath
	local dir = ctx.packageDir
	local modulesDir = ctx.modulesDir
	local makePath = ctx.makePath or function(p) return p end

	local srcFiles = {}
	const sourceList = src.sources ---@cast sourceList string[]
	for _, s in ipairs(sourceList) do
		srcFiles[#srcFiles + 1] = path.join(dir, s)
	end

	local args = {}
	if ctx.targetFlag then
		args[#args + 1] = ctx.targetFlag
	end
	args[#args + 1] = "-shared"
	if shouldUseFPIC(ctx) then
		args[#args + 1] = "-fPIC"
	end
	args[#args + 1] = "-DLUAJIT_VERSION=LuaJIT 2.1.0-beta3"
	args[#args + 1] = "-DLUA_VERSION_NUM=501"
	args[#args + 1] = "-I" .. path.join(ljPath, "include")
	const defines = src.defines or {} ---@cast defines string[]
	for _, d in ipairs(defines) do args[#args + 1] = "-D" .. d end
	if jitOS == "Windows" then
		-- compat-5.3 selects strerror_r when _XOPEN_SOURCE >= 600 (which
		-- lprefix.h defines), but UCRT only provides strerror_s.
		args[#args + 1] = "-DCOMPAT53_HAVE_STRERROR_R=0"
		args[#args + 1] = "-DCOMPAT53_HAVE_STRERROR_S=1"
	end
	-- incdirs/libdirs entries may be absolute, package-relative, or $(VAR)
	-- placeholders (unknown vars are skipped).
	const dirVars = {
		LUA_INCDIR = path.join(ljPath, "include"),
		LUA_LIBDIR = path.join(ljPath, "lib"),
		PREFIX = modulesDir,
		LUADIR = modulesDir,
		LIBDIR = modulesDir,
	}
	if ctx.extVars then
		for k, v in pairs(ctx.extVars) do dirVars[k] = v end
	end

	---@param entries string[]
	---@param flag string
	local function addDirs(entries, flag)
		for _, entry in ipairs(entries) do
			local resolved = (entry:gsub("%$%(([%w_]+)%)", function(k) return dirVars[k] or "" end))
			if resolved ~= "" and not resolved:find("$", 1, true) then
				const dirPath = path.isAbsolute(resolved) ? resolved : path.join(dir, resolved)
				args[#args + 1] = flag .. makePath(dirPath)
			end
		end
	end

	const incdirs = src.incdirs or {} ---@cast incdirs string[]
	addDirs(incdirs, "-I")
	for _, s in ipairs(srcFiles) do args[#args + 1] = s end
	args[#args + 1] = "-o"
	args[#args + 1] = ctx.destAbs
	args[#args + 1] = "-L" .. path.join(ljPath, "lib")
	const libdirs = src.libdirs or {} ---@cast libdirs string[]
	addDirs(libdirs, "-L")
	if jitOS == "Windows" then args[#args + 1] = "-lluajit" end
	if jitOS == "OSX" then
		args[#args + 1] = "-undefined"; args[#args + 1] = "dynamic_lookup"
	end
	const libraries = src.libraries or {} ---@cast libraries string[]
	for _, l in ipairs(libraries) do args[#args + 1] = "-l" .. l end
	return args
end

return native
