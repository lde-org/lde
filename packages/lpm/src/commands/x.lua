local ansi = require("ansi")
local env = require("env")

local lpm = require("lpm-core")
local resolvePackage = require("lpm.util.resolve")

---@param pkg lpm.Package
---@param scriptArgs string[]
---@param cwd string
local function executePackage(pkg, scriptArgs, cwd)
	pkg:build()
	pkg:installDependencies()

	local ok, err = pkg:runFile(nil, scriptArgs, nil, cwd)
	if not ok then
		error("Failed to run script: " .. err)
	end
end

---@param args clap.Args
local function x(args)
	local userCwd = env.cwd()

	if not args:option("git") and not args:option("path") and not args:peek() then
		ansi.printf("{red}Usage: lpm x <name>[@<version>] [args...]")
		ansi.printf("{red}       lpm x --git <repo-url> [package-name] [args...]")
		ansi.printf("{red}       lpm x --path <dir> [package-name] [args...]")
		return
	end

	local pkg, err = resolvePackage(args)
	if not pkg then error(err) end

	executePackage(pkg, args:drain() or {}, userCwd)
end

return x
