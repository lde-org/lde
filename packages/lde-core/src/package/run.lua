local fs = require("fs")
local path = require("path")
local ffi = require("ffi")
local process = require("process")
local runtime = require("lde-core.runtime")

---@param package lde.Package
local function getLuaPathsForPackage(package)
	local modulesDir = package:getModulesDir()

	local luaPath =
		path.join(modulesDir, "?.lua") .. ";"
		.. path.join(modulesDir, "?", "init.lua") .. ";"

	local luaCPath =
		ffi.os == "Linux" and path.join(modulesDir, "?.so") .. ";"
		or ffi.os == "Windows" and path.join(modulesDir, "?.dll") .. ";"
		or path.join(modulesDir, "?.dylib") .. ";"

	return luaPath, luaCPath
end

---@param package lde.Package
---@param scriptPath string
---@param args string[]?
---@param vars table<string, string>?
---@param cwd string
---@param profile boolean?
---@param flamegraph string?
local function runFileWithLDE(package, scriptPath, args, vars, cwd, profile, flamegraph, preload)
	local luaPath, luaCPath = getLuaPathsForPackage(package)

	return runtime.executeFile(scriptPath, {
		args = args,
		env = vars,
		cwd = cwd,
		packagePath = luaPath,
		packageCPath = luaCPath,
		profile = profile,
		flamegraph = flamegraph,
		preload = preload
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

---@param package lde.Package
---@param scriptPath string?
---@param args string[]?
---@param vars table<string, string>?
---@param cwd string?
---@param profile boolean?
---@param flamegraph string?
---@return boolean?
---@return string
local function runFile(package, scriptPath, args, vars, cwd, profile, flamegraph, preload)
	package:build()
	local config = package:readConfig()

	if not scriptPath then
		if not config.bin and not fs.exists(path.join(package:getTargetDir(), "init.lua")) then
			return nil,
				"Package '" ..
				(config.name or "?") .. "' has no runnable entry point (no bin defined — it may be a library)"
		end

		scriptPath = config.bin
			and path.join(package:getTargetDir(), config.bin)
			or path.join(package:getTargetDir(), "init.lua")
	end

	cwd = cwd or package:getDir()

	local engine = config.engine or "lde"
	if engine == "lde" or engine == "lpm" --[[ compat ]] then
		return runFileWithLDE(package, scriptPath, args, vars, cwd, profile, flamegraph, preload)
	end
	if profile or flamegraph then
		return nil, "Profiling is only supported when engine is 'lde'"
	end
	return runFileWithLuaCLI(package, scriptPath, args, vars, engine, cwd)
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
	cwd = cwd or package:getDir()

	local engine = config.engine or "lde"
	if engine == "lde" or engine == "lpm" --[[ compat ]] then
		return runStringWithLDE(package, code, args, vars, cwd)
	end
	return runStringWithLuaCLI(package, code, args, vars, engine, cwd)
end

return { runFile = runFile, runString = runString, getLuaPaths = getLuaPathsForPackage }
