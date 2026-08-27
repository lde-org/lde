local fs = require("fs")
local path = require("path")
local process = require("process")
local env = require("env")

-- The fs module exposes rawfs fields (chmod) through its copy loop; declare
-- the ones used here so the language server sees them.
---@class fs
---@field chmod fun(p: string, mode: number): boolean

--- Polyfills for the subset of the LuaRocks runtime API that custom build
--- backends expect (luarocks.fs, luarocks.dir, luarocks.path,
--- luarocks.core.cfg, luarocks.util), implemented on lde's own fs/path/process
--- deps and injected into a rocked sandbox guest state.

-- Shell prefix for fs.execute: cmd.exe on Windows, sh elsewhere. Allocated
-- once at module load rather than per command.
local SHELL = jit.os == "Windows" and { "cmd", "/c" } or { "sh", "-c" }

--- Permission gate for sandbox side effects. `permissions` maps an action
--- name (e.g. "execute") to a callback that receives the detail (e.g. the
--- command string) and returns whether it may proceed; actions with no
--- callback default to allow. A future interactive prompt plugs in here.
---@param permissions rocked.Permissions?
---@param action string
---@param detail string
---@return boolean
local function checkPermission(permissions, action, detail)
	local allow = permissions and permissions[action]
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
	-- cmd.exe re-parses the command line with its own quote rules, so pass the
	-- already-quoted script string through verbatim (unsafe) instead of the
	-- MSVCRT-style per-arg escaping process applies on Windows.
	local opts = jit.os == "Windows" and { unsafe = true } or nil
	if cwd then opts = opts or {}; opts.cwd = cwd end
	local code = process.exec(SHELL[1], { SHELL[2], cmd }, opts)
	return code == 0
end

---@param tool string
---@return boolean
local function toolAvailable(tool)
	local sep = jit.os == "Windows" and ";" or ":"
	local exe = jit.os == "Windows" and (tool .. ".exe") or tool
	for dir in (os.getenv("PATH") or ""):gmatch("[^" .. sep .. "]+") do
		if dir ~= "" and fs.exists(path.join(dir, exe)) then return true end
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

--- Create a directory under the system temp dir and return its path.
---@param name string
---@return string
local function makeTempDir(name)
	local p = path.join(env.tmpdir(), name)
	fs.mkdirAll(p)
	return p
end

--- List the immediate entries of a directory. Returns the names as multiple
--- string values — host callbacks can only return primitives, so the guest
--- assembles them into a table.
---@param dir string
local function listDirNames(dir)
	local names = {}
	local iter = fs.readdir(dir)
	if iter then
		for entry in iter do names[#names + 1] = entry.name end
	end
	return unpack(names)
end

--- Recursively list the files under a directory (relative paths), as multiple
--- string values for the guest to assemble.
---@param dir string
local function findFiles(dir)
	local files = {}
	if fs.isdir(dir) then
		for _, rel in ipairs(fs.scan(dir, "**")) do files[#files + 1] = rel end
	end
	return unpack(files)
end

--- Inject the polyfills into a guest state. The modules are plain host tables
--- (functions become callbacks); assigning them through the package.loaded
--- proxy coerces them into the guest by value, so require() returns them
--- directly. package.preload can't hold them — preload entries are loader
--- functions, and require() calls them.
local luarocks = {}
---@param state lua.State
---@param opts rocked.SandboxOpts?
function luarocks.setup(state, opts)
	opts = opts or {}

	local cwd = opts.cwd or ""
	local libDir = opts.libDir or ""

	local platform = jit.os == "Windows" and "windows"
		or (jit.os == "OSX" and "osx" or "unix")

	local ext = platform == "windows" and "dll"
		or (platform == "osx" and "dylib")
		or "so"

	local g = state:globals() --[[@as { package: { loaded: table<string, any> } }]]
	local loaded = g.package.loaded
	loaded["luarocks.fs"] = {
		exists            = fs.exists,
		is_dir            = fs.isdir,
		make_dir          = fs.mkdirAll,
		copy              = copyWithMode,
		delete            = fs.delete,
		execute           = function(cmd) return runCommand(cmd, cwd ~= "" and cwd or nil, opts.permissions) end,
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
		lua_dir     = function(_name, _version) return libDir end,
		install_dir = function(_name, _version) return libDir end,
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
		get_luajit_version = function() return jit.version end,
		printout           = print,
		printerr           = function(s) io.stderr:write(tostring(s) .. "\n") end,
	}

	-- fs.execute_env receives a guest env table, which the bridge cannot pass
	-- to a host callback, so the flattening lives guest-side on top of
	-- fs.execute. list_dir/find likewise can't get a table back from a host
	-- callback, so their host helpers return entries variadically and the
	-- guest assembles them.
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
