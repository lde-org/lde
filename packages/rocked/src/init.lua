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

--- The rockspec `test` section: `type` selects the backend, `script`/`command` are
--- the command backend's payload, `flags` are prepended to the runner's args.
---@class rocked.raw.Test
---@field type string?
---@field script string?
---@field command string?
---@field flags string[]?
---@field busted_executable string?
---@field platforms table<string, { flags: string[]? , script: string?, command: string? }>?

--- The rockspec `source` section. `dir` names the source directory inside an
--- archive, `file` the archive's own name, `md5` its expected digest.
---@class rocked.raw.Source
---@field url string
---@field branch string?
---@field tag string?
---@field dir string?
---@field file string?
---@field md5 string?

---@class rocked.raw.Output
---@field version string
---@field package string
---@field rockspec_format string?
---@field description rocked.raw.Description?
---@field source rocked.raw.Source
---@field dependencies string[]?
---@field build_dependencies string[]?
---@field test_dependencies string[]?
---@field external_dependencies table<string, { library?: string|string[], header?: string|string[], program?: string|string[] }>?
---@field test rocked.raw.Test?
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
---@field permissions rocked.Permissions? # per-action gates; unlisted actions default to allow
---@field luaBin string? # interpreter path backends see as cfg.variables.LUA
---@field luaDir string? # mock Lua install dir backends see as cfg.variables.LUA_DIR
---@field luaIncDir string?
---@field luaLibDir string?
---@field variables table<string, string>? # extra cfg.variables entries (overrides)

--- A rockspec runs with an empty environment. The shared string metatable stays
--- intact: rockspecs compute versions from strings (`("1.0"):gsub(...)`) and
--- LuaRocks accepts that, so detaching it rejected ~5% of published rockspecs for
--- no security gain — the string library does no I/O and `load` is not in the
--- environment.
const ROCKSPEC_ENV = {}

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

--- A chunk's environment is its whole view of the world, so building it from the
--- whitelist *is* the isolation: the guest keeps its standard library, the sandboxed
--- chunk never sees it. Clearing the globals table key by key instead cost a bridge
--- round trip per key (~0.7 µs, hundreds per state) and tripped a LuaJIT trace-exit
--- bug (lj_snap_restore) on the bulk deletion.
local ENV_LOADER = [==[
	local source, chunkName, names = ...
	local env = {}
	for i = 1, #names do
		local name = names[i]
		env[name] = _G[name]
	end
	local f, err = loadstring(source, chunkName)
	if not f then error(err, 0) end
	setfenv(f, env)
	return f, env
]==]

---@param state lua.State
---@param names string[] # globals the chunk may see; nothing else is reachable
---@param code string
---@param chunkName string
---@return lua.Chunk chunk
---@return lua.Table env # the chunk's environment: everything it defines lands here
local function loadInEnv(state, names, code, chunkName)
	if code:byte(1) == BYTECODE_SIGNATURE then
		error("rockspec must be Lua source, not precompiled bytecode", 0)
	end

	const ok, chunk, env = state:load(ENV_LOADER, "@lde-env"):setMode("text"):pcall(code, chunkName, names)
	if not ok then error("rocked: cannot compile the chunk: " .. tostring(chunk), 0) end
	return chunk --[[@as lua.Chunk]], env --[[@as lua.Table]]
end

--- Clears a guest table in place. In place, because LuaJIT's require() reads the module
--- cache from a registry entry that still points at this table; guest-side, because
--- clearing through the bridge costs a round trip per key. Keys are collected first:
--- deleting during a traversal trips a LuaJIT trace-exit bug (lj_snap_restore).
local CACHE_CLEAR = [==[
	local tbl = ...
	local drop = {}
	for k in pairs(tbl) do drop[#drop + 1] = k end
	for i = 1, #drop do tbl[drop[i]] = nil end
]==]

--- Run `fn` against a fresh guest state: an instruction limit (which also keeps the
--- guest on the interpreter, so the count hook fires) and a memory cap.
---@param opts rocked.SandboxOpts?
---@param names string[] # the sandbox's whole global environment
---@param fn fun(state: lua.State, names: string[]): any, any
---@return any ok
---@return any resultOrErr
local function sandbox(opts, names, fn)
	opts = opts or {}
	local state = lua.new()
	const g = state:globals()
	local reachesModules = false
	for _, name in ipairs(names) do
		if name == "require" or name == "package" then reachesModules = true end
	end

	-- The guest keeps its own `package`, but not its search path or module cache: a
	-- backend's require() must reach the installed tree and the polyfills that
	-- `luarocks.setup` registers below, never the standard library.
	const packageTable = g:get("package") --[[@as lua.Table?]]
	if packageTable then
		packageTable:set("path", opts.packagePath or "")
		packageTable:set("cpath", opts.cpath or "")
	end

	state:setHook(function()
		error("Rockspec took too long to run")
	end, "count", opts.instructionLimit or DEFAULT_INSTRUCTION_LIMIT)
	state:setMemoryLimit(opts.memoryLimit or DEFAULT_MEMORY_LIMIT)

	-- Only a chunk that can reach `require` needs the cache emptied; a rockspec has
	-- no globals at all, so its sandbox skips the work.
	if packageTable and reachesModules then
		const clear = state:load(CACHE_CLEAR, "@lde-cache"):setMode("text")
		for _, field in ipairs({ "loaded", "preload" }) do
			const cache = packageTable:get(field) --[[@as lua.Table?]]
			if cache then
				const cleared = clear:pcall(cache)
				if not cleared then error("rocked: cannot clear package." .. field, 0) end
			end
		end
	end

	local ok, a, b = pcall(fn, state, names)
	state:close()
	if not ok then return false, a --[[@as string?]] end
	return a, b
end

--- The sandbox needs lua-sys for chunk modes and memory limits.
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
	return sandbox({ permissions = permissions }, ROCKSPEC_ENV, function(state, names)
		const chunk, env = loadInEnv(state, names, spec, "t")
		const ok, err = chunk:pcall()
		if not ok then return false, err end

		local out = {}
		for _, field in ipairs(ROCKSPEC_FIELDS) do
			const v = env:get(field)
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

--- LuaRocks' test-backend contract: `require("luarocks.test.<type>")` and call
--- `run_tests(rockspec.test, args)`. Returns nil+err instead of raising, since a
--- failing suite is a normal outcome.
local TEST_BACKEND_DRIVER = [[
	local test_type, rockspec, args = ...
	local loaded, driver = pcall(require, "luarocks.test." .. test_type)
	if not loaded then
		error("failed loading test execution module luarocks.test." .. test_type, 0)
	end
	local ok, err = driver.run_tests(rockspec.test, args)
	if ok == nil then
		error(tostring(err or "test backend returned false"), 0)
	end
]]

--- The one sandbox that gets the luarocks.* polyfills, spared from the module-cache strip.
---@param testType string
---@param rockspec table # Host-side rockspec data (coerced into the guest)
---@param args string[] # flags + CLI args, as LuaRocks passes them
---@param opts rocked.SandboxOpts?
---@return boolean ok
---@return string? err
function rocked.runTestBackend(testType, rockspec, args, opts)
	const backendOpts = opts or {}
	return sandbox(backendOpts, luarocks.backendEnv(), function(state, names)
		luarocks.setup(state, backendOpts)
		const chunk = loadInEnv(state, names, TEST_BACKEND_DRIVER, "@lde-test-backend")
		const ok, err = chunk:pcall(testType, state:table(rockspec), state:table(args))
		if ok then return true end
		return false, err --[[@as string?]]
	end)
end

---@param buildType string
---@param rockspec table # Host-side rockspec data (coerced into the guest)
---@param opts rocked.SandboxOpts?
---@return boolean ok
---@return string? err
function rocked.runBackend(buildType, rockspec, opts)
	const backendOpts = opts or {}
	return sandbox(backendOpts, luarocks.backendEnv(), function(state, names)
		luarocks.setup(state, backendOpts)
		const chunk = loadInEnv(state, names, BACKEND_DRIVER, "@lde-backend")
		const ok, err = chunk:pcall(buildType, state:table(rockspec))
		if ok then return true end
		return false, err --[[@as string?]]
	end)
end

return rocked
