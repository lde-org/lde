local Package = require("lpm-core.package")

---@param args clap.Args
local function run(args)
	local pkg, err = Package.open()
	if not pkg then
		error("Failed to open package: " .. err)
	end

	pkg:build()

	pkg:installDependencies()
	if not args:flag("production") then
		pkg:installDevDependencies()
	end

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
