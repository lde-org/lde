const ansi = require("ansi")
const env = require("env")
const fs = require("fs")
const path = require("path")
const lde = require("lde-core")

const resolvePackage = require("lde.util.resolve")
const errorsnippet = require("lde.util.errorsnippet")

---@param pkg lde.Package
---@param scriptArgs string[]
---@param cwd string
local function executePackage(pkg, scriptArgs, cwd)
	pkg:build()
	pkg:installDependencies()

	const ok, result = pkg:runFile(nil, scriptArgs, nil, cwd)
	if not ok then
		-- Remap the built entry (target/<name>/X) to its source (src/X) so snippets point at what the user wrote.
		const targetPrefix = pkg:getTargetDir() .. path.separator
		local srcDir = pkg:getSrcDir()
		const remap = function(file)
			if file:sub(1, #targetPrefix) == targetPrefix then
				const mapped = path.join(srcDir, file:sub(#targetPrefix + 1))
				if fs.exists(mapped) then return mapped end
			end
			return nil
		end
		if errorsnippet.printRunError(pkg:getDir(), result or "Script exited with a non-zero exit code", nil, remap) then
			os.exit(1)
		end
		lde.error.raise(result or "Script exited with a non-zero exit code")
	end

	-- A library entry returns its table instead of running; say so rather than exiting 0 silently.
	if result ~= nil then
		local name = pkg:getName()
		ansi.note("'%s' returned a value instead of running — it looks like a library.", name)
		ansi.tip("Add it as a dependency with `lde add %s` and use `require('%s')` from your own code.", name, name)
	end
end

---@param args clap.Args
local function x(args)
	const userCwd = env.cwd()

	if not args:peek() then
		ansi.eprintf("{red}Usage: lde x <name>[@<version>] [--offline] [args...]")
		ansi.eprintf("{red}       lde x --git <repo-url> [package-name] [args...]")
		ansi.eprintf("{red}       lde x --path <dir> [package-name] [args...]")
		ansi.eprintf("{red}       lde x gh:owner/repo | gh:<pkg>@owner/repo (or github:/gitlab:/codeberg:) [args...]")
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
