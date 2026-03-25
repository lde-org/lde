local fs = require("fs")
local path = require("path")
local ffi = require("ffi")
local process = require("process")
local runtime = require("lpm-core.runtime")

---@param package lpm.Package
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

---@param package lpm.Package
---@param scriptPath string
---@param args string[]?
---@param vars table<string, string>? # Env vars
---@param cwd string
local function runFileWithLPM(package, scriptPath, args, vars, cwd)
	local luaPath, luaCPath = getLuaPathsForPackage(package)

	return runtime.executeFile(scriptPath, {
		args = args,
		env = vars,
		cwd = cwd,
		packagePath = luaPath,
		packageCPath = luaCPath
	})
end

---@param package lpm.Package
---@param scriptPath string
---@param args string[]?
---@param vars table<string, string>? # Env vars
---@param engine string
---@param cwd string
local function runFileWithLuaCLI(package, scriptPath, args, vars, engine, cwd)
	local luaPath, luaCPath = getLuaPathsForPackage(package)

	local env = { LUA_PATH = luaPath, LUA_CPATH = luaCPath }
	if vars then
		for k, v in pairs(vars) do
			env[k] = v
		end
	end

	return process.exec(engine, { scriptPath }, { cwd = cwd, env = env, stdout = "inherit", stderr = "inherit" })
end

--- Runs a script within the package context
--- This will use the package's engine and set up the LUA_PATH accordingly
---@param package lpm.Package
---@param scriptPath string? # Defaults to bin field or target/<name>/init.lua
---@param args string[]? # Positional arguments
---@param vars table<string, string>? # Additional environment variables
---@param cwd string? # Working directory for the script. Defaults to the package directory
---@return boolean? # Success
---@return string # Output
local function runFile(package, scriptPath, args, vars, cwd)
	-- Ensure package is built so modules folder exists (and so it can require itself)
	package:build()

	local config = package:readConfig()

	if not scriptPath then
		if config.bin then
			scriptPath = path.join(package:getTargetDir(), config.bin)
		else
			scriptPath = path.join(package:getTargetDir(), "init.lua")
		end
	end

	cwd = cwd or package:getDir()

	local engine = config.engine or "lpm"
	local ok, err
	if engine == "lpm" then
		ok, err = runFileWithLPM(package, scriptPath, args, vars, cwd)
	else
		ok, err = runFileWithLuaCLI(package, scriptPath, args, vars, engine, cwd)
	end

	if not ok then
		return nil, err or "Script exited with a non-zero exit code"
	end

	return ok, err
end

return runFile
