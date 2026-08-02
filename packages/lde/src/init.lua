local ansi = require("ansi")
local clap = require("clap")
local env = require("env")
local fs = require("fs")
local path = require("path")

-- Enable UTF-8 console output on Windows
if jit.os == "Windows" then
	local ok, win32 = pcall(require, "winapi")
	if ok then
		win32.kernel32.setConsoleOutputCP(win32.kernel32.ConsoleCP.UTF8)
	end
end

local args = clap.parse({ ... })

local cwdOverride = args:option("cwd") or args:short("C")
if cwdOverride then
	local requestedCwd = path.resolve(env.cwd(), cwdOverride)
	if not fs.isdir(requestedCwd) then
		ansi.printf("{red}Error: Directory does not exist: %s", requestedCwd)
		os.exit(1)
	end

	if not env.chdir(requestedCwd) then
		ansi.printf("{red}Error: Failed to change directory: %s", requestedCwd)
		os.exit(1)
	end
end

-- Fast paths that avoid loading lde-core (whose module graph pulls in
-- git2-sys, curl-sys, json, etc.) — this is what dominates CLI startup.

local treeOverride = args:option("tree")
if treeOverride then
	local lde = require("lde-core")
	lde.verbose = true
	lde.global.setDir(treeOverride)
	lde.global.init()
end

if args:flag("version") and args:count() == 0 then
	local ok, v = pcall(require, "lde.version")
	print(ok and v or "0.9.2")
	return
end

local evalCode = args:short("e")
local luaFile = args:flag("lua") and args:pop()

if args:count() == 0 and args:flag("help") then
	require("lde.commands.help")(args)
	return
end

if args:flag("update-path") or args:flag("setup") then
	require("lde.setup")()
	return
end

if args:flag("ensure-mingw") then
	local lde = require("lde-core")
	lde.verbose = true
	lde.global.ensureMingw()
	return
end

local commandName = args:pop()
if (not commandName or commandName == "help") and not evalCode and not luaFile then
	require("lde.commands.help")(args)
	return
end

local lde = require("lde-core")
lde.verbose = true

if evalCode then
	local pkg = lde.Package.open()
	local ok, result
	if pkg then
		pkg:installDependencies()
		ok, result = pkg:runString(evalCode)
	else
		ok, result = lde.runtime.executeString(evalCode)
	end

	if not ok then
		ansi.printf("{red}%s", tostring(result))
	elseif result ~= nil then
		print(tostring(result))
	end

	return
end

if luaFile then
	local ok, err = lde.runtime.executeFile(luaFile, { args = args:drain(), cwd = env.cwd() })
	if not ok then
		ansi.printf("{red}Error: %s", tostring(err)); os.exit(1)
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
	repl      = "lde.commands.repl"
}

-- Commands that don't need the global cache dirs initialized
local noInitCommands = { help = true }

if not noInitCommands[commandName] and not treeOverride then
	lde.global.init()
end

local commandFile = commandFiles[commandName]
if commandFile then
	require(commandFile)(args)
elseif fs.exists(commandName) then
	-- TODO: Replace this hacky behavior
	table.insert(args.raw, 1, commandName)
	require("lde.commands.run")(args)
else
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
	else
		ansi.printf("{red}Unknown command: %s", tostring(commandName))
		os.exit(1)
	end
end
