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

--- A rockspec runs with an empty environment. The shared string metatable stays
--- intact: rockspecs compute versions from strings (`("1.0"):gsub(...)`) and
--- LuaRocks accepts that, so detaching it rejected ~5% of published rockspecs for
--- no security gain — the string library does no I/O and `load` is stripped.
local ROCKSPEC_ENV = {}

--- Guest functions are rejected; only data crosses the boundary.
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

--- Keys are collected first: deleting while iterating a guest table is unsafe.
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

--- Run `source` in a fresh isolated guest state: environment `env`, an instruction
--- limit (keeps the guest on the interpreter so the count hook fires) and a memory cap.
---@param opts rocked.SandboxOpts?
---@param env table<string, boolean> # names the chunk may see; empty for none
---@param fn fun(state: lua.State, g: lua.Table): any, any # (ok, result-or-err); shapes differ per caller
---@return any ok
---@return any resultOrErr
local function sandbox(opts, env, fn)
	opts = opts or {}
	local state = lua.new()
	local g = state:globals()

	-- `package` is reached before the globals strip removes it from _G.
	const packageTable = g:get("package") --[[@as lua.Table?]]

	stripUnwhitelisted(g, env)

	if packageTable then
		packageTable:set("path", opts.packagePath or "")
		packageTable:set("cpath", opts.cpath or "")

		-- The globals strip is not enough: luaL_openlibs also registers stdlibs in package.loaded.
		const extraModules = opts.extraModules
		stripUnwhitelisted(packageTable:get("loaded") --[[@as lua.Table]], env, extraModules)
		stripUnwhitelisted(packageTable:get("preload") --[[@as lua.Table]], env, extraModules)
	end

	-- setHook also disables the guest JIT while installed.
	state:setHook(function()
		error("Rockspec took too long to run")
	end, "count", opts.instructionLimit or DEFAULT_INSTRUCTION_LIMIT)

	state:setMemoryLimit(opts.memoryLimit or DEFAULT_MEMORY_LIMIT)

	local ok, a, b = pcall(fn, state, g)
	state:close()
	if not ok then return false, a --[[@as string?]] end
	return a, b
end

--- Fail closed, since skipping either capability would leave containment looking enforced.
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
			-- Format 3.0+ defaults to a builtin build; older formats require one.
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

--- Names may contain dots, so the name ends at the first whitespace, not the first '.'/operator.
---@param depStr string
---@return string? name
---@return string? version # Constraint such as ">= 1.1.0"; nil when unconstrained
function rocked.parseDependency(depStr)
	local name, rest = depStr:match("^([%w%.%-_]+)%s*(.*)")
	if not name then return nil, nil end
	return name, rest ~= "" ? rest : nil
end

---@param depStr string
---@return string? gitUrl
function rocked.gitDependency(depStr)
	const url = depStr:match("^%s*(git%+?%w+://%S+)%s*$")
		or depStr:match("^%s*(git://%S+)%s*$")
		or depStr:match("^%s*(https?://%S+%.git)%s*$")
	return url
end

--- A named constant so the long literal is not an unindented argument expression.
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

--- The one sandbox that gets the luarocks.* polyfills, spared from the module-cache strip.
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
