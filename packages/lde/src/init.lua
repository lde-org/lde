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

	if not baseDir:match("^/") and not baseDir:match("^%a:[/\\]") then
		local cwd = isWindows and io.popen("cd"):read("*l") or io.popen("pwd"):read("*l")
		baseDir = cwd .. separator .. baseDir
	end

	local ldeModulesDir = join(baseDir, "target")

	local function exists(path)
		local ok, _, code = os.rename(path, path)
		if not ok then
			return code == 13 -- permission denied means it exists
		end
		return true
	end

	local function mkdir(dir)
		if not exists(dir) then
			if isWindows then
				os.execute('mkdir "' .. dir .. '"')
			else
				os.execute('mkdir -p "' .. dir .. '"')
			end
		end
	end

	-- Semantics of src differ between Windows and Unix symlinks: Windows needs
	-- an absolute path for junction points, Unix prefers relative for portability.
	local function mklink(src, dest, absSrc)
		if not exists(dest) then
			if isWindows then
				os.execute('mklink /J "' .. dest .. '" "' .. absSrc .. '"')
			else
				os.execute("ln -sf '" .. src .. "' '" .. dest .. "'")
			end
		end
	end

	mkdir(ldeModulesDir)

	local pathPackages = {
		"ansi", "clap", "git", "luarocks", "readline",
		"sea", "semver", "util", "lde-core", "lde-test", "rocked"
	}

	for _, pkg in ipairs(pathPackages) do
		mklink(
			join("..", "..", pkg, "src"),
			join(ldeModulesDir, pkg),
			join(baseDir, "..", pkg, "src")
		)
	end

	local tmpBase = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
	local tmpLDEDir = join(tmpBase, "lde")

	---@type { name: string, url: string }[]
	local gitPackages = {
		{ name = "fs",          url = "https://github.com/lde-org/fs" },
		{ name = "env",         url = "https://github.com/lde-org/env" },
		{ name = "process",     url = "https://github.com/lde-org/process" },
		{ name = "path",        url = "https://github.com/lde-org/path" },
		{ name = "archive",     url = "https://github.com/lde-org/archive" },
		{ name = "git",         url = "https://github.com/lde-org/git" },
		{ name = "json",        url = "https://github.com/lde-org/json" },
		{ name = "ffix",        url = "https://github.com/lde-org/ffix" },
		{ name = "curl-sys",    url = "https://github.com/lde-org/curl-sys" },
		{ name = "git2-sys",    url = "https://github.com/lde-org/git2-sys" },
		{ name = "deflate-sys", url = "https://github.com/lde-org/deflate-sys" }
	}

	mkdir(tmpLDEDir)

	for _, pkg in ipairs(gitPackages) do
		local moduleDistPath = join(ldeModulesDir, pkg.name)
		if not exists(moduleDistPath) then
			local cloneDir = join(tmpLDEDir, pkg.name)
			if not exists(cloneDir) then
				os.execute('git clone --depth 1 --recurse-submodules --shallow-submodules "' ..
					pkg.url .. '" "' .. cloneDir .. '"')
			end

			local buildScript = join(cloneDir, "build.lua")
			if exists(buildScript) then
				if isWindows then
					os.execute('xcopy /E /I /Y "' .. join(cloneDir, "src") .. '" "' .. moduleDistPath .. '"')
					os.execute('cd /d "' ..
						cloneDir .. '" && set LDE_OUTPUT_DIR=' .. moduleDistPath .. ' && luajit "' .. buildScript .. '"')
				else
					os.execute('cp -r "' .. join(cloneDir, "src") .. '/." "' .. moduleDistPath .. '"')
					os.execute('cd "' ..
						cloneDir .. '" && LDE_OUTPUT_DIR="' .. moduleDistPath .. '" luajit "' .. buildScript .. '"')
				end
			else
				mklink(join(cloneDir, "src"), moduleDistPath, join(cloneDir, "src"))
			end
		end
	end

	mklink(join("..", "src"), join(ldeModulesDir, "lde"), join(baseDir, "src"))
end

local ansi = require("ansi")
local clap = require("clap")
local env = require("env")
local fs = require("fs")
local path = require("path")

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
	repl      = "lde.commands.repl",
}

-- Commands that don't need the global cache dirs initialized
local noInitCommands = { help = true }

local commandName = args:pop()
if not commandName then
	require("lde.commands.help")(args)
	return
end

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
	end
end
