local ansi = require("ansi")
local env = require("env")
local lde = require("lde-core")

local resolvePackage = require("lde.util.resolve")

---@param pkg lde.Package
---@param scriptArgs string[]
---@param cwd string
local function executePackage(pkg, scriptArgs, cwd)
	pkg:build()
	pkg:installDependencies()

	local ok, err = pkg:runFile(nil, scriptArgs, nil, cwd)
	if not ok then
		lde.error.raise(err or "Script exited with a non-zero exit code")
	end
end

---@param args clap.Args
local function x(args)
	local userCwd = env.cwd()

	if not args:peek() then
		ansi.printf("{red}Usage: lde x <name>[@<version>] [--offline] [args...]")
		ansi.printf("{red}       lde x --git <repo-url> [package-name] [args...]")
		ansi.printf("{red}       lde x --path <dir> [package-name] [args...]")
		return
	end

	local pkg, err = resolvePackage(args)
	if not pkg then
		lde.error.raise(err)
	end ---@cast pkg -nil

	args:flag("") -- consume -- separator if present
	executePackage(pkg, args:drain() or {}, userCwd)
end

return x
