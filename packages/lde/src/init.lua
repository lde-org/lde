if select("#", ...) == 0 then
	require("lde.commands.help").main()
	return
end

const clap = require("clap")
const usage = require("lde.commands.usage")
const suggest = require("lde.util.suggest")

const args = clap.parse({ ... })

-- Everything after `--lua` is the interpreter's, so split it off before any lde
-- option parsing.
local luaCliArgs
if args:flag("lua") then
	luaCliArgs = args:drain()
end

-- Global flag consumed before the command name is popped so it works anywhere.
const verboseRequested = args:flag("verbose")

-- Parsed up front so --version is seen even with -C/--tree, applied after the check.
const cwdOverride  = args:option("cwd") or args:short("C")
const treeOverride = args:option("tree")

-- Separate so the --version path can apply -C/--tree; heavy modules load lazily.
local function applyOverrides()
	if cwdOverride then
		const ansi = require("ansi")
		local env = require("env")
		local fs = require("fs")
		local path = require("path")
		local cwd = env.cwd()
		local requestedCwd
		if not cwd then
			-- nil cwd = the process's cwd was deleted; only an absolute -C still works.
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
	elseif treeOverride then
		local lde = require("lde-core")
		lde.global.setDir(treeOverride)
		lde.global.init()
	end
end

-- Avoids loading lde-core (git2-sys/curl-sys/json), which dominates startup.
-- Only intercept --version/-v as the first remaining arg: a command's own
-- `--version <value>` must reach it, or clap's flag() would silently eat it.
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

const evalCode = args:short("e")

	-- Inside the boundary so unknown targets render cleanly; help.lua lazy-loads
	-- lde-core.
	const helpRequested = args:flag("help")

-- Hidden completion backend for the generated shell scripts, kept off lde-core.
if args:peek() == "__complete" then
	args:pop()
	require("lde.commands.complete")(args)
	return
end

-- UTF-8 console output on Windows, needed for test output.
if jit.os == "Windows" then
	local ok, win32 = pcall(require, "winapi")
	if ok then
		win32.kernel32.setConsoleOutputCP(win32.kernel32.ConsoleCP.UTF8)
	end
end

-- Known errors render as one clean message; anything unexpected gets the
-- "lde crashed" traceback screen.
	local ok, boundaryErr = xpcall(function()
	applyOverrides()

	-- Through the boundary so `lde --help <unknown>` renders a clean error.
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

	-- Mirrors Package.open's discovery: a manifest or a standalone *.rockspec.
	---@return boolean
	local function cwdHasPackageManifest()
		local f = io.open("lpm.json", "rb")
		if f then f:close() return true end
		f = io.open("lde.json", "rb")
		if f then f:close() return true end
		local fs = require("fs")
		const iter = fs.readdir(".")
		if iter then
			for entry in iter do
				if entry.type == "file" and entry.name:match("%.rockspec$") then
					return true
				end
			end
		end
		return false
	end

	-- Outside a package, -e needs no core library, so take a runtime-only fast path.
	if evalCode and not luaCliArgs and not cwdHasPackageManifest() then
		local env = require("env")
		if not env.cwd() then
			require("lde-core.error").raise("Current working directory no longer exists (it may have been deleted); use an absolute path with -C or cd to an existing directory")
		end
		local eok, result = require("lde-core.runtime").executeString(evalCode)
		if not eok then
			require("lde-core.error").raise(tostring(result))
		elseif result ~= nil then
			print(tostring(result))
		end
		return
	end

	-- lde-core is required here (after the fast commands) so startup stays ~1ms.
	-- Compact output by default; --verbose restores streaming; LDE_VERBOSE carries
	-- the choice to the hidden build worker.
	local lde = require("lde-core")
	if os.getenv("LDE_VERBOSE") == "1" or verboseRequested then
		lde.isVerbose = true
	end

	-- Fail cleanly when the shell's cwd was deleted instead of crashing on
	-- path.resolve(nil, ...).
	if not require("env").cwd() then
		lde.error.raise("Current working directory no longer exists (it may have been deleted); use an absolute path with -C or cd to an existing directory")
	end

	if commandName == "--ensure-mingw" or args:flag("ensure-mingw") then
		lde.global.ensureMingw()
		return
	end

	-- Runs build.lua in a subprocess so the install scheduler can overlap native
	-- builds (see lde-core/package/build.lua).
	if commandName == "__build-pkg" then
		const pkgDir = args:pop()
		local outDir = args:pop()
		const targetName = args:pop()
		const buildLog = require("lde-core.util.build-log")
		-- Capture all build output; on failure write it to the deterministic
		-- buildLog.pathFor temp file and exit (the parent renders the error).
		const capture = (not lde.isVerbose) ? buildLog.newCapture() : nil
		local ok, msg = pcall(function()
			if not pkgDir or not outDir then
				error("__build-pkg: missing package dir or output dir", 0)
			end
			-- Inherit the target so build.lua C code builds for the target platform.
			if targetName and targetName ~= "" then
				local target, terr = require("sea").getTarget(targetName)
				if not target then
					error("__build-pkg: " .. (terr or ("unknown target '" .. targetName .. "'")), 0)
				end ---@cast target -nil
				lde.global.setTarget(target)
			end
			local pkg, perr = lde.Package.open(pkgDir)
			if not pkg then
				error("__build-pkg: " .. (perr or "failed to open package"), 0)
			end ---@cast pkg -nil
			const bok, berr = pkg:runBuildScript(outDir, capture)
			if not bok then error(berr or "build failed", 0) end
		end)
		if not ok then
			-- Capture the error itself: a build failing before any subprocess output
			-- would otherwise leave the log empty.
			if capture then
				capture:append("__build-pkg: " .. lde.error.message(msg) .. "\n")
				if outDir then capture:write(outDir) end
			end
			os.exit(1)
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
		const lok, lerr = lde.runtime.executeLuaCLI(luaCliArgs, { cwd = require("env").cwd() })
		if not lok then
			lde.error.raise(lerr)
		end
		return
	end

	const commandFiles = {
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
		bloat     = "lde.commands.bloat",
		test      = "lde.commands.test",
		tree      = "lde.commands.tree",
		update    = "lde.commands.update",
		outdated  = "lde.commands.outdated",
		uninstall = "lde.commands.uninstall",
		publish   = "lde.commands.publish",
		completion = "lde.commands.completion",
		repl      = "lde.commands.repl"
	}

	-- A path-shaped arg on a missing file must report the missing path, not fall
	-- through to "Unknown command".
	---@param name string
	---@return boolean
	local function looksLikePath(name)
		if name:sub(1, 2) == "./" or name:sub(1, 3) == "../" then return true end
		if name:sub(1, 1) == "/" or name:sub(1, 2) == "~/" then return true end
		if jit.os == "Windows" then
			if name:sub(1, 2) == ".\\" or name:sub(1, 3) == "..\\" then return true end
			if name:sub(1, 1) == "\\" or name:match("^%a:[/\\]") then return true end
		end
		return false
	end

	const noInitCommands = { help = true, completion = true }

	if not noInitCommands[commandName] and not treeOverride then
		lde.global.init()
	end

	const commandFile = commandFiles[commandName]
	if commandFile then
		require(commandFile)(args)
	elseif require("fs").exists(commandName) then
		---@cast args { raw: string[] }
		table.insert(args.raw, 1, commandName) ---@cast args clap.Args
		require("lde.commands.run")(args)
	else
		local pkg = lde.Package.open()
		const scripts = pkg and pkg:readConfig().scripts

		if scripts and scripts[commandName] then ---@cast pkg -nil

			-- npm-style: everything after `--` is passed to the script as its args.
			local scriptArgs = {}
			const isDash, dashPos = args:flag("")
			if isDash then
				scriptArgs = args:drain(dashPos + 1)
			end

			pkg:build()
			pkg:installDependencies()

			const sok, serr = pkg:runScript(commandName, nil, scriptArgs)
			if not sok then
				lde.error.raise("Script '" .. commandName .. "' failed: " .. (serr or "exited with a non-zero exit code"))
			end
		else
			if looksLikePath(commandName) then
				lde.error.raise("No file at path '" .. commandName .. "'")
			end

			local hint = suggest.command(commandName, usage.names)
			lde.error.raise("Unknown command " .. require("ansi").colorize("yellow", '"' .. tostring(commandName) .. '"'), { hint = hint })
		end
	end
end, function(e)
	return { value = e, trace = debug.traceback(tostring(e), 2) }
end)

if not ok then ---@cast boundaryErr { value: any, trace: string? }
	require("lde-core.error").show(boundaryErr.value, boundaryErr.trace)
end
