local lua = require("lua-sys")
local luarocks = require("rocked.luarocks")

local rocked = {}

---@class rocked.raw.Description
---@field summary string
---@field detailed string
---@field homepage string
---@field license string

---@class rocked.raw.NativeSource
---@field sources string[]
---@field defines string[]?
---@field libraries string[]?
---@field incdirs string[]?
---@field libdirs string[]?

---@alias rocked.raw.BuildSource
--- | string
--- | rocked.raw.NativeSource

---@class rocked.raw.BuildInstall
---@field lua table<string, string>?
---@field bin table<string, string>?
---@field lib table<string, string>?
---@field conf table<string, string>?

---@class rocked.raw.PlatformBuild
---@field modules table<string, rocked.raw.BuildSource>?
---@field install rocked.raw.BuildInstall?

---@class rocked.raw.Build
---@field type string
---@field modules table<string, rocked.raw.BuildSource>?
---@field install rocked.raw.BuildInstall?
---@field copy_directories string[]?
---@field platforms table<string, rocked.raw.PlatformBuild>?
---@field makefile string?
---@field build_target string?
---@field install_target string?
---@field variables table<string, string>?
---@field build_variables table<string, string>?
---@field install_variables table<string, string>?
---@field build_command string?
---@field install_command string?

---@class rocked.raw.Output
---@field version string
---@field package string
---@field rockspec_format string?
---@field description rocked.raw.Description?
---@field source { url: string, branch: string?, tag: string? }
---@field dependencies string[]?
---@field build_dependencies string[]?
---@field test_dependencies string[]?
---@field external_dependencies table<string, { library?: string|string[], header?: string|string[], program?: string|string[] }>?
---@field test { type: string?, flags: string[]?, platforms: table<string, { flags: string[]? }>? }?
---@field build rocked.raw.Build

-- ─── Host side of the sandbox ─────────────────────────────────────────────

-- Instruction budget for a rockspec chunk before it is killed.
local DEFAULT_INSTRUCTION_LIMIT = 1e7

---@class rocked.Permissions
---@field execute? fun(command: string): boolean # allow running `command`; default: allow

---@class rocked.SandboxOpts
---@field packagePath string? # package.path for require() inside the sandbox
---@field cpath string?
---@field cwd string? # working directory for fs.execute
---@field libDir string? # what luarocks.path.lib_dir() resolves to
---@field instructionLimit number?
---@field permissions rocked.Permissions? # per-action gates; unlisted actions default to allow

-- Whitelist of globals exposed to the sandbox. Rockspecs are declarative
-- data, so no I/O, process, debug, or FFI access; everything else in the
-- freshly-opened guest state is stripped. The luarocks.* API is provided as
-- polyfills via package.preload (see rocked.luarocks).
local WHITELISTED_LIBS = { "string", "table", "math", "package" }
local WHITELISTED_FUNCS = {
	"assert", "error", "getmetatable", "ipairs", "next", "pairs",
	"pcall", "rawequal", "rawget", "rawset", "require", "select",
	"setmetatable", "tonumber", "tostring", "type", "unpack", "xpcall",
}

--- Convert a guest value (a lua.Table proxy or primitive) into plain host
--- data, recursively. Guest functions are rejected: rockspecs and backends
--- hand data across the boundary, not executable values.
---@param v any
---@return any
local function materialize(v)
	if type(v) == "function" then
		error("rockspec contains executable values (functions); only data is supported", 0)
	end
	if type(v) ~= "table" then return v end
	local mt = getmetatable(v)
	if not (mt and rawget(mt, "_is_lua_value") == true) then return v end
	local out = {}
	for k, val in v:pairs() do
		out[materialize(k)] = materialize(val)
	end
	return out
end

--- Run `source` inside a fresh isolated lua-sys guest state: a whitelisted
--- global surface, an instruction limit (which also keeps the guest on the
--- interpreter so the count hook fires), and luarocks.* polyfills.
---
--- The host callback `fn(state, g)` does the actual work; its first two
--- results become the return values, and any error it raises becomes
--- `(false, err)`.
---@param opts rocked.SandboxOpts?
---@param fn fun(state: lua.State, g: lua.Table): any, any # (ok, result-or-err); shapes differ per caller
---@return any ok
---@return any resultOrErr
local function sandbox(opts, fn)
	opts = opts or {}
	local state = lua.new()
	local g = state:globals()

	local allowed = {}
	for _, name in ipairs(WHITELISTED_LIBS) do allowed[name] = true end
	for _, name in ipairs(WHITELISTED_FUNCS) do allowed[name] = true end
	-- Collect first: deleting keys while iterating a guest table is unsafe.
	local toRemove = {}
	for name in g:pairs() do
		if type(name) == "string" and not allowed[name] then
			toRemove[#toRemove + 1] = name
		end
	end
	for _, name in ipairs(toRemove) do g:set(name, nil) end

	-- require() only resolves preloads and the caller-provided paths.
	local packageTable = g:get("package") --[[@as lua.Table]]
	packageTable:set("path", opts.packagePath or "")
	packageTable:set("cpath", opts.cpath or "")

	-- Instruction budget; setHook also disables the guest JIT while installed.
	state:setHook(function()
		error("Rockspec took too long to run")
	end, "count", opts.instructionLimit or DEFAULT_INSTRUCTION_LIMIT)

	luarocks.setup(state, opts)

	local ok, a, b = pcall(fn, state, g)
	state:close()
	if not ok then return false, a --[[@as string?]] end
	return a, b
end

-- ─── Rockspec parsing ─────────────────────────────────────────────────────

---@type string[]
local ROCKSPEC_FIELDS = {
	"package", "version", "rockspec_format", "description", "source",
	"dependencies", "build_dependencies", "test_dependencies",
	"external_dependencies", "build", "test", "variables",
}

---@overload fun(spec: string): false, string?
---@overload fun(spec: string): true, rocked.raw.Output
---@param spec string
---@param permissions rocked.Permissions? # per-action gates for sandbox side effects
function rocked.parse(spec, permissions)
	return sandbox({ permissions = permissions }, function(state, g)
		local ok, err = state:load(spec, "t"):pcall()
		if not ok then return false, err end

		local out = {}
		for _, field in ipairs(ROCKSPEC_FIELDS) do
			local v = g:get(field)
			if v ~= nil then out[field] = materialize(v) end
		end

		local build = out.build
		if not build then
			-- Rockspec format 3.0+ makes the build table optional: it defaults
			-- to a builtin build (modules are autodetected from the source
			-- tree). Older formats require an explicit build table.
			local format = out.rockspec_format
			local major = format and tonumber(tostring(format):match("^(%d+)"))
			if major and major >= 3 then
				build = { type = "builtin" }
				out.build = build
			else
				return false, "No build section found"
			end
		end

		build.type = build.type or "builtin"
		return true, out
	end)
end

--- Parses a single rockspec dependency string into its package name and
--- optional version constraint.
---
--- LuaRocks names may contain dots (e.g. "fidget.nvim >= 1.1.0"), so the
--- name is everything up to the first whitespace — not up to the first '.'
--- or operator character.
---@param depStr string
---@return string? name
---@return string? version # Constraint such as ">= 1.1.0"; nil when unconstrained
function rocked.parseDependency(depStr)
	local name, rest = depStr:match("^([%w%.%-_]+)%s*(.*)")
	if not name then return nil, nil end
	return name, (rest ~= "" and rest or nil)
end

--- Detects a git dependency in a rockspec dependency string (e.g.
--- "git+https://github.com/x/y", "git://github.com/x/y", or a plain
--- "https://...git" URL) and returns the raw URL, or nil for rock deps.
---@param depStr string
---@return string? gitUrl
function rocked.gitDependency(depStr)
	local url = depStr:match("^%s*(git%+?%w+://%S+)%s*$")
		or depStr:match("^%s*(git://%S+)%s*$")
		or depStr:match("^%s*(https?://%S+%.git)%s*$")
	return url
end

-- ─── Custom build backends ────────────────────────────────────────────────

--- Run a custom build backend (e.g. "rust-mlua") inside the sandbox.
---
--- Mirrors LuaRocks' build dispatch: the backend is a module named
--- `luarocks.build.<type>` provided by a rock named `luarocks-build-<type>`
--- (installed via build_dependencies), and is invoked as
--- `driver.run(rockspec, no_install)`.
---@param buildType string
---@param rockspec table # Host-side rockspec data (coerced into the guest)
---@param opts rocked.SandboxOpts?
---@return boolean ok
---@return string? err
function rocked.runBackend(buildType, rockspec, opts)
	return sandbox(opts, function(state, g)
		local ok, err = state:load([[
			local build_type, rockspec = ...
			-- rockspec:type() is a method on the (guest-coerced) rockspec. It
			-- must live guest-side: a host callback would receive the table as
			-- its self argument, which the bridge cannot pass.
			rockspec.type = function() return "rockspec" end
			local driver = require("luarocks.build." .. build_type)
			local result, buildErr = driver.run(rockspec, false)
			if result ~= true then
				error(tostring(buildErr or "backend returned false"), 0)
			end
		]]):pcall(buildType, state:table(rockspec))
		if ok then return true end
		return false, err --[[@as string?]]
	end)
end

return rocked
