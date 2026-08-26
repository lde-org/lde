local ansi = require("ansi")
local env = require("env")
local fs = require("fs")
local path = require("path")
local lde = require("lde-core")

local resolvePackage = require("lde.util.resolve")
local errorsnippet = require("lde.util.errorsnippet")

---@param pkg lde.Package
---@param scriptArgs string[]
---@param cwd string
local function executePackage(pkg, scriptArgs, cwd)
	pkg:build()
	pkg:installDependencies()

	local ok, result = pkg:runFile(nil, scriptArgs, nil, cwd)
	if not ok then
		-- Map the built entry (target/<name>/X) back to its source (src/X) so
		-- the snippet points at what the user wrote; fall back to the clean
		-- error when there is no file position.
		local targetPrefix = pkg:getTargetDir() .. path.separator
		local srcDir = pkg:getSrcDir()
		local remap = function(file)
			if file:sub(1, #targetPrefix) == targetPrefix then
				local mapped = path.join(srcDir, file:sub(#targetPrefix + 1))
				if fs.exists(mapped) then return mapped end
			end
			return nil
		end
		if errorsnippet.printRunError(pkg:getDir(), result or "Script exited with a non-zero exit code", nil, remap) then
			os.exit(1)
		end
		lde.error.raise(result or "Script exited with a non-zero exit code")
	end

	-- A module (library) entry returns its table instead of running; exiting
	-- 0 with no output reads as "broken", so say what happened.
	if result ~= nil then
		local name = pkg:getName()
		ansi.note("'%s' returned a value instead of running — it looks like a library.", name)
		ansi.tip("Add it as a dependency with `lde add %s` and use `require('%s')` from your own code.", name, name)
	end
end

---@param args clap.Args
local function x(args)
	local userCwd = env.cwd()

	if not args:peek() then
		ansi.printf("{red}Usage: lde x <name>[@<version>] [--offline] [args...]")
		ansi.printf("{red}       lde x --git <repo-url> [package-name] [args...]")
		ansi.printf("{red}       lde x --path <dir> [package-name] [args...]")
		ansi.printf("{red}       lde x gh:owner/repo | gh:<pkg>@owner/repo (or github:/gitlab:/codeberg:) [args...]")
		return
	end

	local pkg, err, hint = resolvePackage(args)
	if not pkg then
		lde.error.raise(err, { hint = hint })
	end ---@cast pkg -nil

	args:flag("") -- consume -- separator if present
	executePackage(pkg, args:drain() or {}, userCwd)
end

return x
