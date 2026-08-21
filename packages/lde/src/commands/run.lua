local env = require("env")
local fs = require("fs")
local path = require("path")
local ansi = require("ansi")

local errorsnippet = require("lde.util.errorsnippet")

local lde = require("lde-core")
local runtime = require("lde-core.runtime")

--- Print a run error with a highlighted source snippet when the file can be
--- located (mirroring test-failure rendering); fall back to the clean error
--- for errors without a file position.
---@param err string
---@param pkgDir string
---@param knownFile? string # the file being executed
---@param remap? fun(file: string): string? # rewrite the error file (target/<name>/X -> src/X)
local function raiseRunError(err, pkgDir, knownFile, remap)
	if errorsnippet.printError(pkgDir, err, knownFile, remap) then
		os.exit(1)
	end
	lde.error.raise(err)
end

--- Resolve the entry point for `lde run [name]` and drive the in-process
--- --hot/--watch loop: the guest state runs in this process, and the driver
--- re-runs the entry point when watched files change (restarting the state
--- for --watch, patching package.loaded for --hot).
---@param pkg lde.Package?
---@param pkgErr string?
---@param name string?
---@param scriptArgs string[]
---@param mode "hot"|"watch"
local function runWithWatcher(pkg, pkgErr, name, scriptArgs, mode)
	if not pkg then
		if not name or not fs.exists(name) then
			lde.error.raise(pkgErr or "No script file given")
		end ---@cast name -nil

		local entry = path.resolve(env.cwd(), name)
		local args = { [0] = entry, unpack(scriptArgs) }
		local watchDirs = { { dir = env.cwd(), recursive = true } }
		local entryDir = path.dirname(entry)
		if entryDir ~= env.cwd() then
			watchDirs[#watchDirs + 1] = { dir = entryDir, recursive = false }
		end

		lde.watchrun.run({
			mode = mode,
			entry = entry,
			args = args,
			watchDirs = watchDirs,
			createState = function()
				return runtime.createState({ args = args, cwd = env.cwd() })
			end,
		})
		return
	end

	pkg:build()
	pkg:installDependencies()

	local config = pkg:readConfig()
	if name and config.scripts and config.scripts[name] then
		if mode == "hot" then
			ansi.printf("{red}--hot only applies to Lua entry points, not shell scripts ('%s')", name)
			return
		end

		-- --watch can still re-run shell scripts (they're child processes, so
		-- the in-process driver's state/hook machinery doesn't apply).
		local watchDir = pkg:getSrcDir()
		local watcher = fs.watch(watchDir, function() end, { recursive = true })
		if not watcher then
			ansi.printf("{red}Failed to watch: %s", watchDir)
			return
		end

		ansi.printf("{cyan}Watching %s for changes...", watchDir)
		while true do
			local ok, err = pkg:runScript(name, nil, scriptArgs)
			if not ok then
				ansi.printf("{red}Error: %s", err or "Script exited with a non-zero exit code")
			end
			watcher.wait()
			ansi.printf("{cyan}Change detected, restarting...")
		end
	end

	local entry
	if name then
		entry = path.resolve(pkg:getDir(), name)
	else
		if not config.bin and not fs.exists(path.join(pkg:getTargetDir(), "init.lua")) then
			ansi.printf("{red}%s",
				"Package '" .. (config.name or "?") .. "' has no runnable entry point (no bin defined — it may be a library)")
			return
		end

		entry = config.bin
			and path.join(pkg:getTargetDir(), (config.bin:gsub("%.tl$", ".lua"):gsub("%.moon$", ".lua")))
			or path.join(pkg:getTargetDir(), "init.lua")
	end

	local args = { [0] = entry, unpack(scriptArgs) }
	local srcDir = pkg:getSrcDir()
	local sep = path.separator

	lde.watchrun.run({
		mode = mode,
		entry = entry,
		args = args,
		watchDirs = { { dir = srcDir, recursive = true } },
		srcPrefix = srcDir .. sep,
		targetPrefix = pkg:getTargetDir() .. sep,
		-- Rebuild before each hot reload so target/ picks up the change (the
		-- stamp check makes this a no-op when nothing changed).
		preReload = mode == "hot" and function()
			local ok, err = pcall(pkg.build, pkg)
			if not ok then
				ansi.printf("{red}Build failed: %s", tostring(err))
			end
			return ok
		end or nil,
		createState = function()
			return pkg:createState({ args = args, cwd = pkg:getDir() })
		end,
	})
end

---@param args clap.Args
local function run(args)
	local pkg, pkgErr = lde.Package.open()

	local scriptArgs ---@type string[]
	local name = nil ---@type string?
	local hot = args:flag("hot")
	local watch = args:flag("watch")
	local profile = args:flag("profile")
	local flamegraph = args:option("flamegraph")
	if not flamegraph and args:flag("flamegraph") then flamegraph = "profile.html" end
	local profileJson = args:option("json")
	if not profileJson and args:flag("json") then profileJson = "profile.json" end

	if (hot or watch) and (profile or flamegraph or profileJson) then
		ansi.printf("{red}--profile/--flamegraph/--json cannot be combined with --hot or --watch")
		return
	end

	local isDash, dashPos = args:flag("")
	if isDash then
		if dashPos ~= 0 then
			name = args:pop()
			scriptArgs = args:drain(dashPos)
		else
			-- -- was first: everything after it is a script arg (drain from 1,
			-- not 0, which would leave a nil hole at index 1).
			scriptArgs = args:drain(1)
		end
	else
		name = args:pop()
		scriptArgs = args:drain()
	end

	if hot or watch then
		runWithWatcher(pkg, pkgErr, name, scriptArgs, hot and "hot" or "watch")
		return
	end

	if not pkg then
		if name and fs.exists(name) then
			local ok, err = runtime.executeFile(name, {
				args = scriptArgs,
				cwd = env.cwd(),
				profile = profile,
				flamegraph = flamegraph
			})

			if not ok then
				raiseRunError(err or "Script exited with a non-zero exit code", env.cwd(), path.resolve(env.cwd(), name))
			end

			return
		end

		lde.error.raise(pkgErr or "No script file given")
	end ---@cast pkg -nil

	pkg:build()
	pkg:installDependencies()

	local scripts = pkg:readConfig().scripts
	local ok, err
	if name and scripts and scripts[name] then
		ok, err = pkg:runScript(name, nil, scriptArgs)
		if not ok then
			lde.error.raise(err or "Script exited with a non-zero exit code")
		end
	else
		-- Map the built entry (target/<name>/X) back to its source (src/X) so
		-- the snippet points at what the user wrote.
		local targetPrefix = pkg:getTargetDir() .. path.separator
		local srcDir = pkg:getSrcDir()
		local remap = function(file)
			if file:sub(1, #targetPrefix) == targetPrefix then
				local mapped = path.join(srcDir, file:sub(#targetPrefix + 1))
				if fs.exists(mapped) then return mapped end
			end
			return nil
		end
		ok, err = pkg:runFile(name, scriptArgs, nil, nil, profile, flamegraph, profileJson)
		if not ok then
			raiseRunError(err or "Script exited with a non-zero exit code", pkg:getDir(), nil, remap)
		end
	end
end

return run
