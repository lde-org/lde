local fs = require("fs")
local path = require("path")
local process = require("process")
const env = require("env")

-- Declared so the language server sees the rawfs fields (chmod) fs.copy uses.
---@class fs
---@field chmod fun(p: string, mode: number): boolean

--- LuaRocks API polyfills for backend sandboxes, built on lde's fs/path/process.

-- Shell prefix for fs.execute, allocated once at module load.
const SHELL = jit.os == "Windows" and { "cmd", "/c" } or { "sh", "-c" }

--- Maps an action name to a callback receiving the detail and returning whether it may proceed.
---@param permissions rocked.Permissions?
---@param action string
---@param detail string
---@return boolean
local function checkPermission(permissions, action, detail)
	const allow = permissions?.[action]
	if allow == nil then return true end
	if type(allow) == "function" then return allow(detail) ~= false end
	return allow ~= false
end

---@param cmd string
---@param cwd string?
---@param permissions rocked.Permissions?
---@return boolean
local function runCommand(cmd, cwd, permissions)
	if not checkPermission(permissions, "execute", cmd) then return false end
	-- cmd.exe re-parses with its own quote rules, so pass the string verbatim (unsafe) on Windows.
	local opts = jit.os == "Windows" and { unsafe = true } or nil
	if cwd then opts = opts or {}; opts.cwd = cwd end
	const code = process.exec(SHELL[1], { SHELL[2], cmd }, opts)
	return code == 0
end

---@param tool string
---@return boolean
local function toolAvailable(tool)
	const sep = jit.os == "Windows" and ";" or ":"
	const exe = jit.os == "Windows" and (tool .. ".exe") or tool
	for dir in (os.getenv("PATH") or ""):gmatch("[^" .. sep .. "]+") do
		if dir ~= "" and fs.exists(path.join(tostring(dir), exe)) then return true end
	end
	return false
end

--- fs.copy with LuaRocks' "exec" mode (chmod +x on POSIX).
---@param src string
---@param dst string
---@param mode string?
---@return boolean ok
---@return string? err
local function copyWithMode(src, dst, mode)
	local ok, err = fs.copy(src, dst)
	if ok and mode == "exec" and jit.os ~= "Windows" then
		fs.chmod(dst, tonumber("755", 8))
	end
	return ok, err
end

---@param p string
---@param relativeTo string?
---@return string
local function absoluteName(p, relativeTo)
	relativeTo = relativeTo or env.cwd()
	if path.isAbsolute(p) then return path.normalize(p) end
	return path.normalize(path.join(relativeTo, p))
end

---@param name string
local function makeTempDir(name)
	local p = path.join(env.tmpdir(), name)
	fs.mkdirAll(p)
	return p
end

--- Multiple values because host callbacks return only primitives; the guest assembles them.
---@param dir string
local function listDirNames(dir)
	const names = {}
	const iter = fs.readdir(dir)
	if iter then
		for entry in iter do names[#names + 1] = entry.name end
	end
	return unpack(names)
end

--- Relative paths, as multiple values for the guest to assemble.
---@param dir string
local function findFiles(dir)
	const files = {}
	if fs.isdir(dir) then
		for _, rel in ipairs(fs.scan(dir, "**")) do files[#files + 1] = rel end
	end
	return unpack(files)
end

const luarocks = {}

-- A backend needs `package` and the data libraries to require its driver, no I/O/process/debug/FFI.
local BACKEND_LIBS = { "string", "table", "math", "package" }
const BACKEND_FUNCS = {
	"assert", "error", "getmetatable", "ipairs", "next", "pairs",
	"pcall", "rawequal", "rawget", "rawset", "require", "select",
	"setmetatable", "tonumber", "tostring", "type", "unpack", "xpcall",
}

---@param libs string[]
---@param funcs string[]
---@return table<string, boolean>
local function allowSet(libs, funcs)
	const allowed = {}
	for _, name in ipairs(libs) do allowed[name] = true end
	for _, name in ipairs(funcs) do allowed[name] = true end
	return allowed
end

const BACKEND_ENV = allowSet(BACKEND_LIBS, BACKEND_FUNCS)

-- Spared when the sandbox strips package.loaded so a backend's require() finds them.
const POLYFILL_MODULES = {
	"luarocks.fs",
	"luarocks.dir",
	"luarocks.path",
	"luarocks.core.cfg",
	"luarocks.util",
}
const POLYFILL_SET = {}
for _, name in ipairs(POLYFILL_MODULES) do POLYFILL_SET[name] = true end

--- True for a module name these polyfills provide, so the sandbox keeps it.
---@param name string
---@return boolean
function luarocks.isPolyfill(name)
	return POLYFILL_SET[name] == true
end

function luarocks.backendEnv()
	return BACKEND_ENV
end

--- The package.loaded proxy coerces the modules into the guest by value, so require() returns them.
---@param state lua.State
---@param opts rocked.SandboxOpts?
function luarocks.setup(state, opts)
	opts = opts or {}

	local cwd = opts.cwd or ""
	const libDir = opts.libDir or ""

	const platform = jit.os == "Windows" and "windows"
		or (jit.os == "OSX" and "osx" or "unix")

	local ext = platform == "windows" and "dll"
		or (platform == "osx" and "dylib")
		or "so"

	const g = state:globals() --[[@as { package: { loaded: table<string, any> } }]]
	const loaded = g.package.loaded
	loaded["luarocks.fs"] = {
		exists            = fs.exists,
		is_dir            = fs.isdir,
		make_dir          = fs.mkdirAll,
		copy              = copyWithMode,
		delete            = fs.delete,
		execute           = function(cmd) return runCommand(cmd, cwd ~= "" ? cwd : nil, opts.permissions) end,
		is_tool_available = toolAvailable,
		current_dir       = env.cwd,
		absolute_name     = absoluteName,
		make_temp_dir     = makeTempDir,
		Q                 = function(s)
			return '"' .. tostring(s):gsub('"', '\\"') .. '"'
		end,
	}
	loaded["luarocks.dir"] = {
		path          = path.join,
		dir_name      = path.dirname,
		absolute_name = absoluteName,
		normalize     = path.normalize,
	}
	loaded["luarocks.path"] = {
		lib_dir     = function(_name, _version) return libDir end,
		lua_dir     = |_name, _version| -> libDir,
		install_dir = |_name, _version| -> libDir,
	}
	loaded["luarocks.core.cfg"] = {
		lua_version            = "5.1",
		luajit_version         = jit.version,
		cache                  = { luajit_version = jit.version },
		is_platform            = function(os) return os == platform end,
		external_lib_extension = ext,
		lib_extension          = ext,
	}
	loaded["luarocks.util"] = {
		get_luajit_version = || -> jit.version,
		printout           = print,
		printerr           = function(s) io.stderr:write(tostring(s) .. "\n") end,
	}

	-- The bridge can't pass a guest env table to a host callback, so flattening happens guest-side.
	local ok, err = state:load([[
		local fs_list, fs_find = ...
		local fs = package.loaded["luarocks.fs"]
		function fs.execute_env(envs, cmd)
			local parts = {}
			for k, v in pairs(envs or {}) do
				parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
			end
			return fs.execute(table.concat(parts, " ") .. " " .. cmd)
		end
		function fs.list_dir(dir)
			return { fs_list(dir) }
		end
		function fs.find(dir)
			return { fs_find(dir) }
		end
	]]):pcall(listDirNames, findFiles)
	if not ok then
		error("failed to install luarocks polyfills: " .. tostring(err))
	end
end

return luarocks
