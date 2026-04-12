-- Bootstrapping mode for initial creation of an lde binary for a platform.
-- Heavily unoptimized, do not use this.
if os.getenv("BOOTSTRAP") then
	local scriptPath = debug.getinfo(1, "S").source:sub(2)
	local srcDir = scriptPath:match("^(.*)[/\\]")
	local baseDir = srcDir:match("^(.*)[/\\]")

	package.path = baseDir .. "/target/?.lua;" ..
		baseDir .. "/target/?/init.lua;" ..
		package.path

	local separator = package.config:sub(1, 1)

	local function join(...)
		return table.concat({ ... }, separator)
	end

	local isWindows = separator == '\\'
	local ldeModulesDir = join(baseDir, "target")

	local function exists(path)
		local ok, _, code = os.rename(path, path)

		if not ok then
			if code == 13 then -- permission denied but exists
				return true
			end

			return false
		end

		return true
	end

	if not exists(ldeModulesDir) then
		if isWindows then
			os.execute('mkdir "' .. ldeModulesDir .. '"')
		else
			os.execute('mkdir -p "' .. ldeModulesDir .. '"')
		end
	end

	local pathPackages = {
		"ansi", "clap", "fs", "env", "path", "json", "git", "luarocks",
		"process2", "sea", "semver", "util", "lde-core", "lde-test", "rocked", "archive"
	}

	for _, pkg in ipairs(pathPackages) do
		-- Semantics of the 'src' differ between windows and linux symlinks
		local relSrcPath = join("..", "..", pkg, "src")
		local absSrcPath = join(baseDir, "..", pkg, "src")

		local moduleDistPath = join(ldeModulesDir, pkg)
		if not exists(moduleDistPath) then
			if isWindows then
				os.execute('mklink /J "' .. moduleDistPath .. '" "' .. absSrcPath .. '"')
			else
				os.execute("ln -sf '" .. relSrcPath .. "' '" .. moduleDistPath .. "'")
			end
		end
	end

	local moduleDistPath = join(ldeModulesDir, "lde")
	if not exists(moduleDistPath) then
		local relSrcPath = join("..", "src")
		local absSrcPath = join(baseDir, "src")

		if isWindows then
			os.execute('mklink /J "' .. moduleDistPath .. '" "' .. absSrcPath .. '"')
		else
			os.execute("ln -sf '" .. relSrcPath .. "' '" .. moduleDistPath .. "'")
		end
	end
end

local ansi = require("ansi")
local clap = require("clap")
local env = require("env")
local fs = require("fs")

local lde = require("lde-core")

-- Enable UTF-8 console output on Windows
if jit.os == "Windows" then
	local ok, win32 = pcall(require, "winapi")
	if ok then
		win32.kernel32.setConsoleOutputCP(win32.kernel32.ConsoleCP.UTF8)
	end
end

lde.verbose = true

local args = clap.parse({ ... })

local treeOverride = args:option("tree")
if treeOverride then
	lde.global.setDir(treeOverride)
	lde.global.init()
end

if args:flag("version") and args:count() == 0 then
	print(lde.global.currentVersion)
	return
end

local evalCode = args:short("e")
if evalCode then
	require("lde.commands.eval")(evalCode)
	return
end

local luaFile = args:flag("lua") and args:pop()
if luaFile then
	local ok, err = lde.runtime.executeFile(luaFile, { args = args:drain(), cwd = env.cwd() })
	if not ok then
		ansi.printf("{red}Error: %s", tostring(err)); os.exit(1)
	end
	return
end

if args:count() == 0 and args:flag("help") then
	require("lde.commands.help")(args)
	return
end

if args:flag("update-path") or args:flag("setup") then
	require("lde.setup")()
	return
end

if args:flag("ensure-mingw") then
	lde.global.ensureMingw()
	return
end

local commands = {}
commands.help = require("lde.commands.help")
commands.init = require("lde.commands.initialize")
commands.new = require("lde.commands.new")
commands.upgrade = require("lde.commands.upgrade")
commands.add = require("lde.commands.add")
commands.remove = require("lde.commands.remove")
commands.run = require("lde.commands.run")
commands.x = require("lde.commands.x")
commands.install = require("lde.commands.install")
commands.i = commands.install
commands.sync = require("lde.commands.sync")
commands.bundle = require("lde.commands.bundle")
commands.compile = require("lde.commands.compile")
commands.test = require("lde.commands.test")
commands.tree = require("lde.commands.tree")
commands.update = require("lde.commands.update")
commands.outdated = require("lde.commands.outdated")
commands.uninstall = require("lde.commands.uninstall")
commands.publish = require("lde.commands.publish")
commands.repl = require("lde.commands.repl")

-- Commands that don't need the global cache dirs initialized
local noInitCommands = { help = true }

local ok, err = xpcall(function()
	local commandName = args:pop()
	if not commandName then
		commands.help(args)
		return
	end

	if not noInitCommands[commandName] and not treeOverride then
		lde.global.init()
	end

	local commandHandler = commands[commandName]

	if commandHandler then
		commandHandler(args)
	else
		-- Fall back to package scripts, then to a loose file if it exists
		local pkg = lde.Package.open()
		local scripts = pkg and pkg:readConfig().scripts

		if scripts and scripts[commandName] then
			---@cast pkg -nil

			pkg:build()
			pkg:installDependencies()

			local ok, err = pkg:runScript(commandName)
			if not ok then
				error("Script '" .. commandName .. "' failed: " .. err)
			end
		elseif fs.exists(commandName) then
			-- TODO: Replace this hacky behavior
			table.insert(args.raw, 1, commandName)
			commands.run(args)
		else
			ansi.printf("{red}Unknown command: %s", tostring(commandName))
		end
	end
end, function(err)
	return { msg = err, trace = debug.traceback(err, 2) }
end)

if not ok then ---@cast err { msg: string, trace: string }
	ansi.printf("{red}Error: %s", tostring(err.msg))

	if env.var("DEBUG") then
		print(err.trace)
	end

	os.exit(1)
end
