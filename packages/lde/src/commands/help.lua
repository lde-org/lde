local ansi = require("ansi")

---@param _args clap.Args
local function help(_args)
	local commands = {
		{ cmd = "run",       ex = nil,           color = "green",   desc = "Execute a project" },
		{ cmd = "x",         ex = "--git <url>", color = "green",   desc = "Run a package from a git repo or path" },
		{ cmd = "repl",      ex = nil,           color = "green",   desc = "Start an interactive LuaJIT REPL" },
		{ cmd = "test",      ex = nil,           color = "green",   desc = "Run project tests" },
		{},
		{ cmd = "new",       ex = "myproject",   color = "red",     desc = "Create a new project" },
		{ cmd = "init",      ex = nil,           color = "red",     desc = "Initialize current directory as a project" },
		{ cmd = "upgrade",   ex = nil,           color = "red",     desc = "Upgrade lde to the latest version" },
		{},
		{ cmd = "install",   ex = nil,           color = "yellow",  desc = "Install deps, or a tool to PATH with --git/--path" },
		{ cmd = "uninstall", ex = "busted",      color = "yellow",  desc = "Uninstall a tool from PATH" },
		{ cmd = "add",       ex = "hood",        color = "yellow",  desc = "Add a dependency (--path <path> or --git <url>)" },
		{ cmd = "remove",    ex = "json",        color = "yellow",  desc = "Remove a dependency" },
		{ cmd = "tree",      ex = nil,           color = "yellow",  desc = "Show the dependency tree" },
		{ cmd = "update",    ex = "clap",        color = "yellow",  desc = "Update dependencies to their latest versions" },
		{ cmd = "outdated",  ex = nil,           color = "yellow",  desc = "Show dependencies with newer versions available" },
		{ cmd = "publish",   ex = nil,           color = "yellow",  desc = "Create a PR to add your package to the registry" },
		{},
		{ cmd = "compile",   ex = nil,           color = "magenta", desc = "Compile current project into an executable" },
		{ cmd = "bundle",    ex = nil,           color = "magenta", desc = "Bundle current project into a single lua file" }
	}

	ansi.printf("{blue}{bold}lde{reset} is a package manager for Lua, written in Lua.\n")
	ansi.printf("{bold}Usage:{reset} lde <command> {magenta}[options]")
	ansi.printf("\n{bold}Commands:{reset}")
	for _, command in ipairs(commands) do
		if not command.cmd then -- Separator
			print("")
		else
			local cmd = ansi.format("{bold}{" .. command.color .. "}" .. command.cmd)
			local ex = ansi.colorize("gray", command.ex or "")

			ansi.printf("  %-23s %-21s %s", cmd, ex, command.desc)
		end
	end

	ansi.printf("{bold}%-25s{reset} {blue} %s", "\nLearn more:", "https://lde.sh")
	ansi.printf("{bold}%-24s{reset} {blue} %s", "Join the discord:", "https://lde.sh/discord")
end

return help
