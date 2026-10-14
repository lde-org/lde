--- Standard rock build variables: the $(VAR) placeholders a rockspec expands in
--- its own build.variables/commands (LuaRocks' `cfg.variables` contract).

local path = require("path")
const env = require("env")

const lde = require("lde-core")

local vars = {}

--- make receives forward-slash paths on Windows: sh (busybox) eats backslashes in
--- unquoted recipes, and Windows tools accept '/'.
---@return fun(p: string): string
function vars.makePathFn()
	if jit.os ~= "Windows" then
		return function(p) return p end
	end
	return function(p) return (p:gsub("\\", "/")) end
end

---@param modulesDir string
---@param luajitPath string
---@param makePath fun(p: string): string
---@return table<string, string>
function vars.standard(modulesDir, luajitPath, makePath)
	return {
		LUA_INCDIR  = makePath(path.join(luajitPath, "include")),
		LUA_LIBDIR  = makePath(path.join(luajitPath, "lib")),
		LUALIB      = "libluajit.a",
		-- Rocks that auto-detect the Lua toolchain (cqueues' luapath) scan
		-- CPPFLAGS for -I dirs; without it they pick up system Lua headers and
		-- link against APIs LuaJIT does not export.
		CPPFLAGS    = makePath("-I" .. path.join(luajitPath, "include")),
		LIBFLAG     = jit.os == "OSX" and "-bundle -undefined dynamic_lookup" or "-shared",
		INST_LIBDIR = makePath(modulesDir),
		INST_LUADIR = makePath(modulesDir),
		LUADIR      = makePath(modulesDir),
		LIBDIR      = makePath(modulesDir),
		PREFIX      = makePath(modulesDir),
		LUA         = makePath(env.execPath() or "")
	}
end

---@param table_ table<string, string>
---@return fun(s: string): string
function vars.substFn(table_)
	return function(s)
		return (s:gsub("%$%(([%w_]+)%)", function(k) return table_[k] or "" end))
	end
end

--- Whether the build must pass -fPIC (POSIX host and target).
function vars.exportFPic()
	return jit.os ~= "Windows" and lde.global.getTarget()?.platform ~= "windows"
end

function vars.ensureMingw()
	if jit.os ~= "Windows" then return nil end
	local mingwBin = path.join(lde.global.getMingwDir(), "bin")
	const curPath = env.var("PATH") or ""
	if curPath:find(mingwBin, 1, true) then return nil end
	return mingwBin .. ";" .. curPath
end

return vars
