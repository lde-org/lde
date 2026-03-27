local env = require("env")
local fs = require("fs")

local lde = require("lde-core")

---@param args clap.Args
local function run(args)
	local pkg, pkgErr = lde.Package.open()

	local scriptArgs = {}
	local name = nil ---@type string?

	local dash, dashPos = args:flag("")
	if dash then
		if dashPos ~= 0 then
			name = args:pop()
		end

		scriptArgs = args:drain(dashPos)
	else
		name = args:pop()
	end

	if not pkg then
		if name and fs.exists(name) then
			local ok, err = lde.runtime.executeFile(name, {
				args = scriptArgs,
				cwd = env.cwd(),
				packagePath = "",
				packageCPath = ""
			})
			if not ok then
				error("Failed to run script: " .. (err or "Script exited with a non-zero exit code"))
			end

			return
		end

		error("Failed to open package: " .. pkgErr)
	end

	pkg:build()

	pkg:installDependencies()
	if not args:flag("production") then
		pkg:installDevDependencies()
	end

	local ok, err
	local scripts = pkg:readConfig().scripts
	if name and scripts and scripts[name] then
		ok, err = pkg:runScript(name)
	else
		ok, err = pkg:runFile(name, scriptArgs)
	end

	if not ok then
		error("Failed to run script: " .. err)
	end
end

return run
