const lua = require("lua-sys")
const luarocks = require("rocked.luarocks")

const rocked = {}

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
const DEFAULT_INSTRUCTION_LIMIT = 1e7
const DEFAULT_MEMORY_LIMIT = 64 * 1024 * 1024
const BYTECODE_SIGNATURE = 27

---@class rocked.Permissions
---@field execute? fun(command: string): boolean # allow running `command`; default: allow

---@class rocked.SandboxOpts
---@field packagePath string? # package.path for require() inside the sandbox
---@field cpath string?
---@field cwd string? # working directory for fs.execute
---@field libDir string? # what luarocks.path.lib_dir() resolves to
---@field instructionLimit number?
---@field memoryLimit number? # bytes the guest state may hold; 0 removes the cap
---@field extraModules? fun(name: string): boolean # module names this sandbox will install itself (backend polyfills)
---@field permissions rocked.Permissions? # per-action gates; unlisted actions default to allow

local ROCKSPEC_ENV = {}

--- Convert a guest value (a lua.Table proxy or primitive) into plain host
--- data, recursively. Guest functions are rejected: rockspecs and backends
--- hand data across the boundary, not executable values.
---@param v any
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

--- Remove every key of a guest table that is not whitelisted, sparing any name
--- that `keep` accepts. Keys are collected before anything is deleted: deleting
--- while iterating a guest table is unsafe.
---@param tbl lua.Table
---@param allowed table<string, boolean>
---@param keep? fun(name: string): boolean # extra names to spare (a backend's polyfills)
local function stripUnwhitelisted(tbl, allowed, keep)
	const drop = {}
	for name in tbl:pairs() do
		if type(name) == "string" and not allowed[name] and not (keep and keep(name)) then
			drop[#drop + 1] = name
		end
	end
	for _, name in ipairs(drop) do tbl:set(name, nil) end
end

---@param state lua.State
local function detachStringMetatable(state)
	local L = state.L
	if L == nil then return end
	const lraw = lua.raw
	const top = lraw.gettop(L)
	lraw.pushstring(L, "")
	if lraw.getmetatable(L, -1) then
		lraw.pushnil(L)
		lraw.setfield(L, -2, "__index")
	end

	lraw.settop(L, top)
end

--- Run `source` inside a fresh isolated lua-sys guest state: an environment of
--- `env` (empty for rockspecs), an instruction limit (which also keeps the
--- guest on the interpreter so the count hook fires) and a memory cap.
---
--- Nothing luarocks-specific lives here. `opts.extraModules` is how the backend
--- path brings in its polyfills: the names they will occupy are spared when the
--- module cache is stripped, and `fn` installs them. A rockspec passes no
--- extras, so its state never has them.
---
--- The host callback `fn(state, g)` does the actual work; its first two
--- results become the return values, and any error it raises becomes
--- `(false, err)`.
---@param opts rocked.SandboxOpts?
---@param env table<string, boolean> # names the chunk may see; empty for none
---@param fn fun(state: lua.State, g: lua.Table): any, any # (ok, result-or-err); shapes differ per caller
---@return any ok
---@return any resultOrErr
local function sandbox(opts, env, fn)
	opts = opts or {}
	local state = lua.new()
	local g = state:globals()

	-- Reach `package` before the globals are stripped: with an empty rockspec
	-- environment the name is gone from `_G` afterwards, but a backend still
	-- needs its path and cpath set.
	const packageTable = g:get("package") --[[@as lua.Table?]]

	stripUnwhitelisted(g, env)

	-- With the string library gone there is no reason for its metatable to
	-- resolve anything, and leaving it wired up would be a way to reach the
	-- library that the `_G` strip just removed.
	if not env.string then detachStringMetatable(state) end

	if packageTable then
		-- require() only resolves preloads and the caller-provided paths.
		packageTable:set("path", opts.packagePath or "")
		packageTable:set("cpath", opts.cpath or "")

		-- Stripping the globals is not enough. `luaL_openlibs` also registers
		-- every standard library in package.loaded, and deleting the global
		-- leaves those tables alive and reachable: a chunk could still call
		-- `package.loaded.os.execute("...")`, read files through
		-- `package.loaded.io`, or reach `debug`. So the module cache is
		-- stripped on the same whitelist as the globals, and package.preload —
		-- the other table require() consults — is emptied so a stale loader
		-- cannot reintroduce one. For a rockspec the whitelist is empty and no
		-- extras are passed, so this clears the cache outright.
		const extraModules = opts.extraModules
		stripUnwhitelisted(packageTable:get("loaded") --[[@as lua.Table]], env, extraModules)
		stripUnwhitelisted(packageTable:get("preload") --[[@as lua.Table]], env, extraModules)
	end

	-- Instruction budget; setHook also disables the guest JIT while installed.
	state:setHook(function()
		error("Rockspec took too long to run")
	end, "count", opts.instructionLimit or DEFAULT_INSTRUCTION_LIMIT)

	state:setMemoryLimit(opts.memoryLimit or DEFAULT_MEMORY_LIMIT)

	local ok, a, b = pcall(fn, state, g)
	state:close()
	if not ok then return false, a --[[@as string?]] end
	return a, b
end

--- Fail closed when the pinned lua-sys predates the two capabilities this
--- sandbox depends on for containment: restricting a chunk to text (so the
--- loader itself refuses bytecode) and capping the guest heap. Silently
--- skipping either would leave the containment looking enforced while it is
--- not, so an old lua-sys is a hard error instead.
---
--- Probed once, on a throwaway state, so an unsupported lua-sys fails at
--- require time rather than on the first package install. When raising the
--- lua-sys floor here, update the version in lde.json too.
local function checkSandboxSupport()
	const probe = lua.new()
	const hasMemoryLimit = type(probe.setMemoryLimit) == "function"
	const hasChunkMode   = type(probe:load("", "probe").setMode) == "function"
	probe:close()

	local missing = {}
	if not hasChunkMode then missing[#missing + 1] = "Chunk:setMode" end
	if not hasMemoryLimit then missing[#missing + 1] = "State:setMemoryLimit" end
	if #missing > 0 then
		error("rocked needs a lua-sys with " .. table.concat(missing, " and ") ..
			" (>= 0.1.2); run `lde update lua-sys`", 0)
	end
end

checkSandboxSupport()

--- Compile a rockspec or backend chunk in the guest state and refuse any
--- precompiled chunk.
---@param state lua.State
---@param code string
---@param chunkName string
---@return lua.Chunk
local function loadSpec(state, code, chunkName)
	if type(code) == "string" and code:byte(1) == BYTECODE_SIGNATURE then
		error("rockspec must be Lua source, not precompiled bytecode", 0)
	end

	return state:load(code, chunkName):setMode("text")
end

-- ─── Rockspec parsing ─────────────────────────────────────────────────────

---@type string[]
const ROCKSPEC_FIELDS = {
	"package", "version", "rockspec_format", "description", "source",
	"dependencies", "build_dependencies", "test_dependencies",
	"external_dependencies", "build", "test", "variables",
}

---@overload fun(spec: string): false, string?
---@overload fun(spec: string): true, rocked.raw.Output
---@param spec string
---@param permissions rocked.Permissions? # per-action gates for sandbox side effects
function rocked.parse(spec, permissions)
	return sandbox({ permissions = permissions }, ROCKSPEC_ENV, function(state, g)
		local ok, err = loadSpec(state, spec, "t"):pcall()
		if not ok then return false, err end

		local out = {}
		for _, field in ipairs(ROCKSPEC_FIELDS) do
			const v = g:get(field)
			if v ~= nil then out[field] = materialize(v) end
		end

		local build = out.build
		if not build then
			-- Rockspec format 3.0+ makes the build table optional: it defaults
			-- to a builtin build (modules are autodetected from the source
			-- tree). Older formats require an explicit build table.
			const format = out.rockspec_format
			const major = format and tonumber(tostring(format):match("^(%d+)"))
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
	return name, rest ~= "" ? rest : nil
end

--- Detects a git dependency in a rockspec dependency string (e.g.
--- "git+https://github.com/x/y", "git://github.com/x/y", or a plain
--- "https://...git" URL) and returns the raw URL, or nil for rock deps.
---@param depStr string
---@return string? gitUrl
function rocked.gitDependency(depStr)
	const url = depStr:match("^%s*(git%+?%w+://%S+)%s*$")
		or depStr:match("^%s*(git://%S+)%s*$")
		or depStr:match("^%s*(https?://%S+%.git)%s*$")
	return url
end

-- ─── Custom build backends ────────────────────────────────────────────────

--- Driver chunk for a custom build backend. Kept as a named constant so the
--- long literal is not an argument expression full of unindented lines.
local BACKEND_DRIVER = [[
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
]]

--- Run a custom build backend (e.g. "rust-mlua") inside the sandbox.
---
--- Mirrors LuaRocks' build dispatch: the backend is a module named
--- `luarocks.build.<type>` provided by a rock named `luarocks-build-<type>`
--- (installed via build_dependencies), and is invoked as
--- `driver.run(rockspec, no_install)`.
---
--- This is the one sandbox that gets the luarocks.* polyfills, whose module
--- names are declared up front so the module cache strip spares them. A
--- rockspec never reaches them: it runs in a state with an empty environment.
---@param buildType string
---@param rockspec table # Host-side rockspec data (coerced into the guest)
---@param opts rocked.SandboxOpts?
---@return boolean ok
---@return string? err
function rocked.runBackend(buildType, rockspec, opts)
	local backendOpts = opts or {}
	backendOpts.extraModules = luarocks.isPolyfill
	return sandbox(backendOpts, luarocks.backendEnv(), function(state, g)
		-- Names in extraModules survived the strip; put the modules there now.
		luarocks.setup(state, backendOpts)
		local ok, err = loadSpec(state, BACKEND_DRIVER, "@lde-backend"):pcall(buildType, state:table(rockspec))
		if ok then return true end
		return false, err --[[@as string?]]
	end)
end

return rocked
