if select("#", ...) == 0 then
	require("lde.commands.help").main()
	return
end

local clap = require("clap")
local usage = require("lde.commands.usage")
local suggest = require("lde.util.suggest")

local args = clap.parse({ ... })

	-- `--lua [args...]` runs the lde binary as a plain Lua interpreter: the
	-- args form a `lua` command line (`-e <code>` chunks, then an optional
	-- script with its args). Everything after the flag belongs to the
	-- interpreter — scripts may pass their own lde-looking options (e.g.
	-- `luarocks install --tree=...` shelled out through the lde binary) — so
	-- it's split off before any lde option parsing.
	local luaCliArgs
	if args:flag("lua") then
		luaCliArgs = args:drain()
	end

-- Parse the overrides up front so --version is detected even when combined
-- with -C/--tree (matching the historical behavior), but don't apply them
-- until after the version check.
local cwdOverride  = args:option("cwd") or args:short("C")
local treeOverride = args:option("tree")

-- Applies -C/--tree. Kept separate so the --version path below can apply
-- them too, while the plain `lde --version` never pays for ansi/env/fs/path
-- or lde-core.
local function applyOverrides()
	local ansi = require("ansi")
	local env = require("env")
	local fs = require("fs")
	local path = require("path")

	if cwdOverride then
		local cwd = env.cwd()
		local requestedCwd
		if not cwd then
			-- env.cwd() returns nil when the process's cwd no longer exists
			-- (deleted while the shell was open). Only an absolute -C can
			-- still get us somewhere useful in that state.
			if not path.isAbsolute(cwdOverride) then
				ansi.printf("{red}error{gray}:{reset} Current working directory no longer exists (it may have been deleted); use an absolute path with -C or cd to an existing directory")
				os.exit(1)
			end

			requestedCwd = path.normalize(cwdOverride)
		else
			requestedCwd = path.resolve(cwd, cwdOverride)
		end
		if not fs.isdir(requestedCwd) then
			ansi.printf("{red}error{gray}:{reset} Directory does not exist: %s", requestedCwd)
			os.exit(1)
		end

		if not env.chdir(requestedCwd) then
			ansi.printf("{red}error{gray}:{reset} Failed to change directory: %s", requestedCwd)
			os.exit(1)
		end
	end

	if treeOverride then
		local lde = require("lde-core")
		lde.isVerbose = true
		lde.global.setDir(treeOverride)
		lde.global.init()
	end

	return ansi, env, fs, path
end

-- Fast paths that avoid loading lde-core (whose module graph pulls in
-- git2-sys, curl-sys, json, etc.) — this is what dominates CLI startup.
-- `-v` is the single-dash alias for `--version` and shares its fast path and
-- override-combination semantics (`lde -v --tree <dir>` applies the override
-- before printing).
-- A top-level `--version`/`-v` prints the version, but only when it is the
-- first remaining argument (the cwd/tree overrides above are consumed first).
-- A command's own `--version <value>` option — e.g. `lde add x --version
-- 1.0` — must not be intercepted here: clap's flag() would consume it and the
-- command would silently never see its value.
local versionRequested = false
if args:peek() == "--version" or args:peek() == "-v" then
	args:pop()
	versionRequested = true
end

if versionRequested and args:count() == 0 then
	if cwdOverride or treeOverride then
		applyOverrides()
	end
	local ok, v = pcall(require, "lde.version")
	print(ok and v or "0.11.0")
	return
end

local evalCode = args:short("e")

	-- `--help` before a command shows that command's help; alone it shows the
	-- main help. Handled inside the boundary (after applyOverrides) so unknown
	-- targets render cleanly; help.lua lazy-loads lde-core, so plain `lde
	-- --help` still pays nothing beyond ansi/env/fs/path.
	local helpRequested = args:flag("help")

-- Hidden completion backend invoked by the generated shell scripts. Handled
-- before the overrides and lde-core load so tab-completion stays fast.
if args:peek() == "__complete" then
	args:pop()
	require("lde.commands.complete")(args)
	return
end

-- Enable UTF-8 console output on Windows, needed for test output
if jit.os == "Windows" then
	local ok, win32 = pcall(require, "winapi")
	if ok then
		win32.kernel32.setConsoleOutputCP(win32.kernel32.ConsoleCP.UTF8)
	end
end

-- Everything from here on runs through the error boundary: known errors
-- (lde.error.raise) render as a single clean message, anything unexpected is
-- treated as a bug and gets the "lde crashed" screen with a traceback. The
-- fast paths above (--version/--help/__complete/--lua) stay outside so plain
-- queries never pay for lde-core.
	local ok, boundaryErr = xpcall(function()
	local ansi, env, fs = applyOverrides()

	-- `--help` before a command shows that command's help; alone it shows the
	-- main help. Runs through the boundary so `lde --help <unknown>` renders
	-- a clean error; help.lua lazy-loads lde-core so the success path stays fast.
	if helpRequested and not evalCode and not luaCliArgs then
		local target = args:pop()
		if target then
			require("lde.commands.help").forCommand(target)
		else
			require("lde.commands.help").main()
		end
		return
	end

	if args:flag("update-path") or args:flag("setup") then
		require("lde.setup")()
		return
	end

	local commandName
	if not evalCode and not luaCliArgs then
		commandName = args:pop()
		if not commandName or commandName == "help" then
			require("lde.commands.help").main(args)
			return
		end
	end

	-- Everything below needs the full core library. Keep the fast commands
	-- above (bare `lde`, `lde help`, `--setup`) free of lde-core so startup
	-- stays ~1ms; the boundary's crash renderer requires it lazily instead.
	local lde = require("lde-core")
	lde.isVerbose = true

	-- env.cwd() returns nil when the shell's cwd was deleted out from under
	-- it (relative FS ops then act on the orphaned directory, so commands
	-- don't fail on their own). Every command below operates relative to
	-- cwd — fail cleanly instead of crashing on path.resolve(nil, ...).
	if not env.cwd() then
		lde.error.raise("Current working directory no longer exists (it may have been deleted); use an absolute path with -C or cd to an existing directory")
	end

	if commandName == "--ensure-mingw" or args:flag("ensure-mingw") then
		lde.global.ensureMingw()
		return
	end

	-- Hidden build worker: run a package's build.lua in a subprocess so the
	-- install scheduler can overlap independent native builds (see
	-- lde-core/package/build.lua). Invoked as: lde __build-pkg <pkgDir> <outDir>.
	if commandName == "__build-pkg" then
		local pkgDir = args:pop()
		local outDir = args:pop()
		if not pkgDir or not outDir then
			lde.error.raise("__build-pkg: missing package dir or output dir")
		end ---@cast outDir -nil
		local pkg, perr = lde.Package.open(pkgDir)
		if not pkg then
			lde.error.raise("__build-pkg: " .. (perr or "failed to open package"))
		end ---@cast pkg -nil
		local bok, berr = pkg:runBuildScript(outDir)
		if not bok then
			lde.error.raise("__build-pkg: " .. (berr or "build failed"))
		end
		return
	end

	if evalCode then
		local pkg = lde.Package.open()
		local eok, result
		if pkg then
			pkg:installDependencies()
			eok, result = pkg:runString(evalCode)
		else
			eok, result = lde.runtime.executeString(evalCode)
		end

		if not eok then
			lde.error.raise(tostring(result))
		elseif result ~= nil then
			print(tostring(result))
		end

		return
	end

	if luaCliArgs then
		local lok, lerr = lde.runtime.executeLuaCLI(luaCliArgs, { cwd = env.cwd() })
		if not lok then
			lde.error.raise(lerr)
		end
		return
	end

	local commandFiles = {
		help      = "lde.commands.help",
		init      = "lde.commands.initialize",
		new       = "lde.commands.new",
		upgrade   = "lde.commands.upgrade",
		add       = "lde.commands.add",
		remove    = "lde.commands.remove",
		run       = "lde.commands.run",
		x         = "lde.commands.x",
		search    = "lde.commands.search",
		install   = "lde.commands.install",
		i         = "lde.commands.install",
		sync      = "lde.commands.sync",
		bundle    = "lde.commands.bundle",
		compile   = "lde.commands.compile",
		test      = "lde.commands.test",
		tree      = "lde.commands.tree",
		update    = "lde.commands.update",
		outdated  = "lde.commands.outdated",
		uninstall = "lde.commands.uninstall",
		publish   = "lde.commands.publish",
		completion = "lde.commands.completion",
		repl      = "lde.commands.repl"
	}

	-- Commands that don't need the global cache dirs initialized
	local noInitCommands = { help = true, completion = true }

	if not noInitCommands[commandName] and not treeOverride then
		lde.global.init()
	end

	local commandFile = commandFiles[commandName]
	if commandFile then
		require(commandFile)(args)
	elseif fs.exists(commandName) then
		-- TODO: Replace this hacky behavior
		---@cast args { raw: string[] }
		table.insert(args.raw, 1, commandName) ---@cast args clap.Args
		require("lde.commands.run")(args)
	else
		local pkg = lde.Package.open()
		local scripts = pkg and pkg:readConfig().scripts

		if scripts and scripts[commandName] then ---@cast pkg -nil

			-- npm-style: everything after `--` is passed to the script as its args.
			local scriptArgs = {}
			local isDash, dashPos = args:flag("")
			if isDash then
				scriptArgs = args:drain(dashPos + 1)
			end

			pkg:build()
			pkg:installDependencies()

			local sok, serr = pkg:runScript(commandName, nil, scriptArgs)
			if not sok then
				lde.error.raise("Script '" .. commandName .. "' failed: " .. (serr or "exited with a non-zero exit code"))
			end
		else
			local hint = suggest.command(commandName, usage.names)
			lde.error.raise("Unknown command " .. ansi.colorize("yellow", '"' .. tostring(commandName) .. '"'), { hint = hint })
		end
	end
end, function(e)
	return { value = e, trace = debug.traceback(tostring(e), 2) }
end)

if not ok then ---@cast boundaryErr { value: any, trace: string? }
	require("lde-core.error").show(boundaryErr.value, boundaryErr.trace)
end
