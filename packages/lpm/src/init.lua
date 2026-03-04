-- Bootstrapping mode for initial creation of an lpm binary for a platform.
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
	local lpmModulesDir = join(baseDir, "target")

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

	if not exists(lpmModulesDir) then
		if isWindows then
			os.execute('mkdir "' .. lpmModulesDir .. '"')
		else
			os.execute('mkdir -p "' .. lpmModulesDir .. '"')
		end
	end

	local pathPackages = {
		"ansi", "clap", "fs", "http", "env", "path", "json",
		"process", "sea", "semver", "util", "lpm-core", "lpm-test"
	}

	for _, pkg in ipairs(pathPackages) do
		-- Semantics of the 'src' differ between windows and linux symlinks
		local relSrcPath = join("..", "..", pkg, "src")
		local absSrcPath = join(baseDir, "..", pkg, "src")

		local moduleDistPath = join(lpmModulesDir, pkg)
		if not exists(moduleDistPath) then
			if isWindows then
				os.execute('mklink /J "' .. moduleDistPath .. '" "' .. absSrcPath .. '"')
			else
				os.execute("ln -sf '" .. relSrcPath .. "' '" .. moduleDistPath .. "'")
			end
		end
	end

	local moduleDistPath = join(lpmModulesDir, "lpm")
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
local process = require("process")

local global = require("lpm-core.global")
global.init()

local args = clap.parse({ ... })

if args:flag("version") and args:count() == 0 then
	print(global.currentVersion)
	return
end

if args:flag("update-path") or args:flag("setup") then
	require("lpm.setup")()
	return
end

local commands = {}
commands.help = require("lpm.commands.help")
commands.init = require("lpm.commands.initialize")
commands.new = require("lpm.commands.new")
commands.upgrade = require("lpm.commands.upgrade")
commands.add = require("lpm.commands.add")
commands.remove = require("lpm.commands.remove")
commands.run = require("lpm.commands.run")
commands.x = require("lpm.commands.x")
commands.install = require("lpm.commands.install")
commands.i = commands.install
commands.bundle = require("lpm.commands.bundle")
commands.compile = require("lpm.commands.compile")
commands.test = require("lpm.commands.test")
commands.tree = require("lpm.commands.tree")
commands.update = require("lpm.commands.update")
commands.uninstall = require("lpm.commands.uninstall")

local ok, err = xpcall(function()
	if args:count() == 0 then
		commands.help(args)
	else
		local commandName = args:pop()
		local commandHandler = commands[commandName]

		if commandHandler then
			commandHandler(args)
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
end
