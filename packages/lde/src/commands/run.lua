const env = require("env")
const fs = require("fs")
const path = require("path")
const ansi = require("ansi")

const errorsnippet = require("lde.util.errorsnippet")

const lde = require("lde-core")
const runtime = require("lde-core.runtime")

-- Falls back to the clean error when no file position can be located.
---@param err string
---@param pkgDir string
---@param knownFile? string # the file being executed
---@param remap? fun(file: string): string? # rewrite the error file (target/<name>/X -> src/X)
local function raiseRunError(err, pkgDir, knownFile, remap)
	if errorsnippet.printRunError(pkgDir, err, knownFile, remap) then
		os.exit(1)
	end
	lde.error.raise(err)
end

-- --watch restarts the guest state; --hot patches package.loaded instead. Both re-run the entry point on change.
---@param pkg lde.Package?
---@param pkgErr string?
---@param name string?
---@param scriptArgs string[]
---@param mode "hot"|"watch"
---@param jitDiag boolean? # install JIT diagnostics (live trace-abort warnings)
local function runWithWatcher(pkg, pkgErr, name, scriptArgs, mode, jitDiag)
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
			entryLabel = path.basename(entry),
			args = args,
			watchDirs = watchDirs,
			onError = function(err)
				return errorsnippet.printRunError(env.cwd(), err, entry)
			end,
			createState = function()
				local st, g, cleanup = runtime.createState({ args = args, cwd = env.cwd() })
				if jitDiag then
					require("lde-core.jitdiag").install(st, { cwd = env.cwd() })
				end
				return st, g, cleanup
			end,
		})
		return
	end

	pkg:build()
	pkg:installDependencies()

	const config = pkg:readConfig()
	if name and config.scripts and config.scripts[name] then
		if mode == "hot" then
			ansi.printf("{red}--hot only applies to Lua entry points, not shell scripts ('%s')", name)
			return
		end

		-- --watch can still re-run shell scripts: they're child processes, so the in-process driver's state/hook machinery doesn't apply.
		local watchDir = pkg:getSrcDir()
		const watcher = fs.watch(watchDir, function() end, { recursive = true })
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

	-- target/<name>/X errors display as src/X, matching plain `lde run`.
	local remap = function(file)
		local targetPrefix = pkg:getTargetDir() .. path.separator
		if file:sub(1, #targetPrefix) == targetPrefix then
			local mapped = path.join(srcDir, file:sub(#targetPrefix + 1))
			if fs.exists(mapped) then return mapped end
		end
		return nil
	end

	lde.watchrun.run({
		mode = mode,
		entry = entry,
		-- Editing src/init.lua re-runs the whole package: report it as the package, not a module (it has no require() path).
		entryLabel = name ? path.basename(entry) : config.name,
		args = args,
		watchDirs = { { dir = srcDir, recursive = true } },
		srcPrefix = srcDir .. sep,
		targetPrefix = pkg:getTargetDir() .. sep,
		onError = function(err)
			return errorsnippet.printRunError(pkg:getDir(), err, entry, remap)
		end,
		-- Rebuild before each hot reload so target/ picks up the change (the stamp check makes it a no-op when unchanged).
		preReload = mode == "hot" ? function()
			local ok, err = pcall(pkg.build, pkg)
			if not ok then
				ansi.printf("{red}Build failed: %s", tostring(err))
			end
			return ok
		end : nil,
		createState = function()
			local st, g, cleanup = pkg:createState({ args = args, cwd = pkg:getDir() })
			if jitDiag then
				require("lde-core.jitdiag").install(st, { cwd = pkg:getDir() })
			end
			return st, g, cleanup
		end,
	})
end

---@param args clap.Args
local function run(args)
	local pkg, pkgErr = lde.Package.open()

	local scriptArgs ---@type string[]
	local name = nil ---@type string?
	const hot = args:flag("hot")
	local watch = args:flag("watch")
	local profile = args:flag("profile")
	local flamegraph = args:option("flamegraph")
	if not flamegraph and args:flag("flamegraph") then flamegraph = "profile.html" end
	local profileJson = args:option("json")
	if not profileJson and args:flag("json") then profileJson = "profile.json" end
	-- JIT diagnostics (LuaJIT -jv style): report trace aborts with source locations and reasons.
	local jitDiag = args:flag("jit")

	if (hot or watch) and (profile or flamegraph or profileJson) then
		ansi.printf("{red}--profile/--flamegraph/--json cannot be combined with --hot or --watch")
		return
	end

	const isDash, dashPos = args:flag("")
	if isDash then
		if dashPos ~= 0 then
			name = args:pop()
			scriptArgs = args:drain(dashPos)
		else
			-- -- was first: drain from 1, not 0, which would leave a nil hole at index 1.
			scriptArgs = args:drain(1)
		end
	else
		name = args:pop()
		scriptArgs = args:drain()
	end

	if hot or watch then
		runWithWatcher(pkg, pkgErr, name, scriptArgs, hot and "hot" or "watch", jitDiag)
		return
	end

	if not pkg then
		if name and fs.exists(name) then
			local ok, err = runtime.executeFile(name, {
				args = scriptArgs,
				cwd = env.cwd(),
				profile = profile,
				flamegraph = flamegraph,
				jit = jitDiag,
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

	const scripts = pkg:readConfig().scripts
	local ok, err
	if name and scripts and scripts[name] then
		ok, err = pkg:runScript(name, nil, scriptArgs)
		if not ok then
			lde.error.raise(err or "Script exited with a non-zero exit code")
		end
	else
		-- Map the built entry (target/<name>/X) back to its source (src/X) so the snippet points at what the user wrote.
		local targetPrefix = pkg:getTargetDir() .. path.separator
		local srcDir = pkg:getSrcDir()
		local remap = function(file)
			if file:sub(1, #targetPrefix) == targetPrefix then
				local mapped = path.join(srcDir, file:sub(#targetPrefix + 1))
				if fs.exists(mapped) then return mapped end
			end
			return nil
		end
		ok, err = pkg:runFile(name, scriptArgs, nil, nil, profile, flamegraph, profileJson, nil, jitDiag)
		if not ok then
			raiseRunError(err or "Script exited with a non-zero exit code", pkg:getDir(), nil, remap)
		end
	end
end

return run
