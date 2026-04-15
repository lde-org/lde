local env = require("env")
local fs = require("fs")
local ansi = require("ansi")
local process = require("process2")

local lde = require("lde-core")

---@param args clap.Args
local function run(args)
	local pkg, pkgErr = lde.Package.open()

	local scriptArgs ---@type string[]
	local name = nil ---@type string?
	local watch = args:flag("watch")
	local profile = args:flag("profile")
	local flamegraph = args:option("flamegraph")
	if not flamegraph and args:flag("flamegraph") then flamegraph = "profile.html" end

	local dash, dashPos = args:flag("")
	if dash then
		if dashPos ~= 0 then
			name = args:pop()
		end

		scriptArgs = args:drain(dashPos)
	else
		name = args:pop()
		scriptArgs = args:drain()
	end

	local function execute()
		if not pkg then
			if name and fs.exists(name) then
				local ok, err = lde.runtime.executeFile(name, {
					args = scriptArgs,
					cwd = env.cwd(),
					packagePath = "",
					packageCPath = "",
					profile = profile,
					flamegraph = flamegraph
				})
				if not ok then
					error("Failed to run script: " .. (err or "Script exited with a non-zero exit code"))
				end
				return
			end

			ansi.printf("{red}%s\n", pkgErr)
			return
		end

		pkg:build()
		pkg:installDependencies()

		local ok, err
		local scripts = pkg:readConfig().scripts
		if name and scripts and scripts[name] then
			ok, err = pkg:runScript(name)
		else
			ok, err = pkg:runFile(name, scriptArgs, nil, nil, profile, flamegraph)
		end

		if not ok then
			error("Failed to run script: " .. err)
		end
	end

	if not watch then
		execute()
		return
	end

	local watchDir = pkg and pkg:getSrcDir() or env.cwd()
	local watcher = fs.watch(watchDir, function() end, { recursive = true })
	if not watcher then
		error("Failed to watch: " .. watchDir)
	end

	ansi.printf("{cyan}Watching %s for changes...\n", watchDir)

	local spawnArgs = { "run" }
	if profile then spawnArgs[#spawnArgs + 1] = "--profile" end
	if flamegraph then spawnArgs[#spawnArgs + 1] = "--flamegraph=" .. flamegraph end
	if name then spawnArgs[#spawnArgs + 1] = name end
	if #scriptArgs > 0 then
		spawnArgs[#spawnArgs + 1] = "--"
		for _, a in ipairs(scriptArgs) do spawnArgs[#spawnArgs + 1] = a end
	end

	local function spawnChild()
		local child, err = process.spawn(env.execPath(), spawnArgs, { stdout = "inherit", stderr = "inherit" })
		if not child then
			ansi.printf("{red}Error: %s\n", tostring(err))
		end
		return child
	end

	local child = spawnChild()

	while true do
		watcher.wait()
		ansi.printf("{cyan}Change detected, restarting...\n")
		if child then child:kill() end
		child = spawnChild()
	end
end

return run
