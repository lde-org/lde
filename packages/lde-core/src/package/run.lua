const run = {}
package.loaded[(...)] = run

const fs = require("fs")
const path = require("path")
const ffi = require("ffi")
const process = require("process")
const runtime = require("lde-core.runtime")

---@param package lde.Package
local function getLuaPathsForPackage(package)
	local modulesDir = package:getModulesDir()

	local luaPath =
		path.join(modulesDir, "?.lua") .. ";"
		.. path.join(modulesDir, "?", "init.lua") .. ";"

	local luaCPath =
		ffi.os == "Linux" and path.join(modulesDir, "?.so") .. ";"
		or ffi.os == "Windows" and path.join(modulesDir, "?.dll") .. ";"
		or path.join(modulesDir, "?.so") .. ";" .. path.join(modulesDir, "?.dylib") .. ";"

	return luaPath, luaCPath
end

---@param package lde.Package
---@param scriptPath string
---@param args string[]?
---@param vars table<string, string>?
---@param cwd string
---@param profile boolean?
---@param flamegraph string?
---@param preload table<string, function>?
---@param profileJson string?
---@param jit boolean? # JIT diagnostics (trace-abort report)
local function runFileWithLDE(package, scriptPath, args, vars, cwd, profile, flamegraph, preload, profileJson, jit)
	local luaPath, luaCPath = getLuaPathsForPackage(package)

	return runtime.executeFile(scriptPath, {
		args = args,
		env = vars,
		cwd = cwd,
		packagePath = luaPath,
		packageCPath = luaCPath,
		profile = profile,
		flamegraph = flamegraph,
		preload = preload,
		profileJson = profileJson,
		jit = jit,
	})
end

---@param package lde.Package
---@param code string
---@param args string[]?
---@param vars table<string, string>?
---@param cwd string
local function runStringWithLDE(package, code, args, vars, cwd)
	local luaPath, luaCPath = getLuaPathsForPackage(package)
	return runtime.executeString(code, {
		args = args,
		env = vars,
		cwd = cwd,
		packagePath = luaPath,
		packageCPath = luaCPath
	})
end

---@param package lde.Package
---@param scriptPath string
---@param args string[]?
---@param vars table<string, string>?
---@param engine string
---@param cwd string
local function runFileWithLuaCLI(package, scriptPath, args, vars, engine, cwd)
	local luaPath, luaCPath = getLuaPathsForPackage(package)
	local env = { LUA_PATH = luaPath, LUA_CPATH = luaCPath }
	if vars then for k, v in pairs(vars) do env[k] = v end end
	local code, _, stderr = process.exec(engine, { scriptPath },
		{ cwd = cwd, env = env, stdout = "inherit", stderr = "inherit" })
	return code == 0, stderr or "Script exited with a non-zero exit code"
end

---@param package lde.Package
---@param code string
---@param args string[]?
---@param vars table<string, string>?
---@param engine string
---@param cwd string
local function runStringWithLuaCLI(package, code, args, vars, engine, cwd)
	local luaPath, luaCPath = getLuaPathsForPackage(package)
	local env = { LUA_PATH = luaPath, LUA_CPATH = luaCPath }
	if vars then for k, v in pairs(vars) do env[k] = v end end
	local exitCode, _, stderr = process.exec(engine, { "-e", code, unpack(args or {}) },
		{ cwd = cwd, env = env, stdout = "inherit", stderr = "inherit" })
	return exitCode == 0, stderr or "Script exited with a non-zero exit code"
end

--- Whether an entry point has to be executed rather than interpreted: a native
--- executable (ELF, PE, Mach-O) or a script for another runtime (a rock whose
--- build installs a shell/python/… CLI wrapper). Rockspec builds produce both —
--- yuescript's CMake build yields the yue C++ binary, luasocket's make build a
--- shell wrapper — and reading either as Lua source only fails with a syntax
--- error partway through the file. A Lua script that carries a shebang
--- (moonscript's bin/moon starts with `#!/usr/bin/env lua`) stays on the lde
--- runtime, so it runs against the package's dependency tree rather than
--- whatever interpreter happens to be on PATH.
---@param scriptPath string
local function isForeignEntry(scriptPath)
	local file = io.open(scriptPath, "rb")
	if not file then return false end
	local head = file:read(128) or ""
	file:close()

	if head:sub(1, 4) == "\127ELF" or head:sub(1, 2) == "MZ" then return true end
	-- Mach-O: 32/64-bit (FEEDFACE/FEEDFACF) and their byte-swapped forms.
	const b1, b2, b3, b4 = head:byte(1), head:byte(2), head:byte(3), head:byte(4)
	if b1 == 0xFE and b2 == 0xED and b3 == 0xFA and (b4 == 0xCE or b4 == 0xCF) then return true end
	if b1 == 0xCE and b2 == 0xFA and b3 == 0xED and b4 == 0xFE then return true end
	if b1 == 0xCF and b2 == 0xFA and b3 == 0xED and b4 == 0xFE then return true end
	if b1 == 0xCA and b2 == 0xFE and b3 == 0xBA and b4 == 0xBE then return true end

	const shebang = head:match("^#!([^\r\n]*)")
	if shebang then
		-- The interpreter name decides: `env lua`, `/usr/bin/lua5.1`, `luajit`
		-- and friends keep the lde runtime (moonscript's bin/moon), while a
		-- shell/python/node wrapper is a foreign script.
		const interpreter = shebang:match("([^/%s]+)%s*$") or shebang
		return interpreter:match("^lua") == nil
	end
	return false
end

---@param package lde.Package
---@param scriptPath string?
---@param args string[]?
---@param vars table<string, string>?
---@param cwd string?
---@param profile boolean?
---@param flamegraph string?
---@param profileJson string?
---@param preload table<string, function>?
---@param jit boolean?
---@return boolean?
---@return string
local function runFile(package, scriptPath, args, vars, cwd, profile, flamegraph, profileJson, preload, jit)
	package:build()
	local config = package:readConfig()

	if not scriptPath then
		if not config.bin and not fs.exists(path.join(package:getTargetDir(), "init.lua")) then
			return nil,
				"Package '" ..
				(config.name or "?") .. "' has no runnable entry point (no bin defined — it may be a library)"
		end

		scriptPath = config.bin
			and path.join(package:getTargetDir(), (config.bin:gsub("%.tl$", ".lua"):gsub("%.moon$", ".lua")))
			or path.join(package:getTargetDir(), "init.lua")
	end

	local cwd = cwd or package:getDir()

	if fs.isfile(scriptPath) and isForeignEntry(scriptPath) then
		-- Profiling, JIT diagnostics and hot reload all live in the lde runtime;
		-- a spawned program has none of them.
		if profile or flamegraph or profileJson or jit or preload then
			return nil, "Profiling, JIT diagnostics and hot reload are only supported for Lua entry points"
		end
		local luaPath, luaCPath = getLuaPathsForPackage(package)
		const env = { LUA_PATH = luaPath, LUA_CPATH = luaCPath }
		if vars then for k, v in pairs(vars) do env[k] = v end end
		const code, _, stderr = process.exec(scriptPath, args or {}, { cwd = cwd, env = env, stdout = "inherit", stderr = "inherit" })
		if not code or code ~= 0 then
			return nil, (stderr ~= "" and stderr)
				or ("Failed to execute '" .. scriptPath .. "' (it is not executable?)")
		end
		return true
	end

	local engine = config.engine or "lde"
	if engine == "lde" or engine == "lpm" --[[ compat ]] then
		return runFileWithLDE(package, scriptPath, args, vars, cwd --[[@as string]], profile, flamegraph, preload, profileJson, jit)
	end
	if profile or flamegraph or profileJson then
		return nil, "Profiling is only supported when engine is 'lde'"
	end
	return runFileWithLuaCLI(package, scriptPath, args, vars, engine, cwd --[[@as string]])
end

---@param package lde.Package
---@param code string
---@param args string[]?
---@param vars table<string, string>?
---@param cwd string?
---@return boolean?
---@return string
local function runString(package, code, args, vars, cwd)
	package:build()
	local config = package:readConfig()
	local cwd = cwd or package:getDir()

	local engine = config.engine or "lde"
	if engine == "lde" or engine == "lpm" --[[ compat ]] then
		return runStringWithLDE(package, code, args, vars, cwd)
	end
	return runStringWithLuaCLI(package, code, args, vars, engine, cwd)
end

--- Build the package, install its dependencies, and create an isolated guest
--- state with the package's target/ on package.path/cpath — the same setup
--- lde run uses. The caller keeps the state open to drive it (eval chunks, a
--- REPL loop, ...); call cleanup() and state:close() when done.
---
---@param package lde.Package
---@param opts lde.ExecuteOptions?
---@return lua.State state
---@return lua.Table g      # live proxy of the guest globals
---@return fun()     cleanup # restores cwd and env vars on the host
local function createStateForPackage(package, opts)
	package:build()
	package:installDependencies()

	opts = opts or {}
	local luaPath, luaCPath = getLuaPathsForPackage(package)

	return runtime.createState({
		args = opts.args,
		cwd = opts.cwd,
		env = opts.env,
		packagePath = luaPath,
		packageCPath = luaCPath,
		preload = opts.preload,
		globals = opts.globals,
	})
end

run.runFile = runFile
run.runString = runString
run.createState = createStateForPackage
run.getLuaPaths = getLuaPathsForPackage

return run
