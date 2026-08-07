local ansi = require("ansi")

local usage = require("lde.commands.usage")

local ok, currentVersion = pcall(require, "lde.version")
currentVersion = ok and currentVersion or "0.10.0"

--- Render a table of options as aligned rows: "  --flag <arg>  desc".
---@param opts table<string, { arg?: string, desc: string }>
local function printOptions(opts)
	local rows = {}
	for flag, info in pairs(opts) do
		local left = flag .. (info.arg and (" <" .. info.arg .. ">") or "")
		rows[#rows + 1] = { left = left, desc = info.desc }
	end
	table.sort(rows, function(a, b) return a.left < b.left end)

	local width = 0
	for _, row in ipairs(rows) do
		width = math.max(width, #row.left)
	end

	for _, row in ipairs(rows) do
		ansi.printf("  {green}%-" .. width .. "s{reset}  %s", row.left, row.desc)
	end
end

--- Print detailed help for a single command (`lde help <command>`).
---@param name string
local function forCommand(name)
	local canonical = usage.aliases[name] or name
	local spec = usage.commands[canonical]
	if not spec then
		ansi.printf("{red}Unknown command: %s", name)
		ansi.printf("{gray}Run {bold}lde help{reset}{gray} to see all commands.")
		os.exit(1)
	end

	ansi.printf("{bold}{blue}Usage:{reset} %s", spec.usage)
	ansi.printf("{bold}{blue}Description:{reset} %s", spec.description)

	if name ~= canonical then
		ansi.printf("{gray}(alias for {bold}lde %s{reset}{gray})", canonical)
	end

	if spec.arguments then
		ansi.printf("\n{bold}Arguments:{reset}")
		ansi.printf("  %s", spec.arguments)
	end

	if spec.options then
		ansi.printf("\n{bold}Options:{reset}")
		printOptions(spec.options)
	end

	ansi.printf("\n{bold}Global options:{reset}")
	printOptions(usage.globalFlags)

	local topLevel = {}
	for flag, info in pairs(usage.topLevelFlags) do
		topLevel[#topLevel + 1] = flag .. (info.arg and (" <" .. info.arg .. ">") or "")
	end
	table.sort(topLevel)
	ansi.printf("{gray}Top-level flags (before a command): %s{reset}", table.concat(topLevel, ", "))
end

---@param args? clap.Args
local function main(args)
	if args and args:count() > 0 then
		local target = args:pop()
		if target then
			forCommand(target)
			return
		end
	end

	local commands = {
			{ cmd = "help",      ex = nil,           color = "green",   desc = "Show help for a command" },
			{ cmd = "run",       ex = nil,           color = "green",   desc = "Execute a project" },
			{ cmd = "x",         ex = "--git <url>", color = "green",   desc = "Run a package from a git repo or path" },
			{ cmd = "repl",      ex = nil,           color = "green",   desc = "Start an interactive LuaJIT REPL" },
			{ cmd = "test",      ex = nil,           color = "green",   desc = "Run project tests" },
			{},
			{ cmd = "new",       ex = "myproject",   color = "red",     desc = "Create a new project" },
			{ cmd = "init",      ex = nil,           color = "red",     desc = "Initialize current directory as a project" },
			{ cmd = "upgrade",   ex = nil,           color = "red",     desc = "Upgrade lde to the latest version" },
			{},
			{ cmd = "sync",      ex = nil,           color = "yellow",  desc = "Install dependencies (--locked: from lockfile only)" },
			{ cmd = "install",   ex = "rocks:busted", color = "yellow",  desc = "Install a tool to PATH with --git/--path/rocks:" },
			{ cmd = "uninstall", ex = "busted",      color = "yellow",  desc = "Uninstall a tool from PATH" },
			{ cmd = "add",       ex = "hood",        color = "yellow",  desc = "Add a dependency (--path <path> or --git <url>)" },
			{ cmd = "remove",    ex = "json",        color = "yellow",  desc = "Remove a dependency" },
			{ cmd = "tree",      ex = nil,           color = "yellow",  desc = "Show the dependency tree" },
			{ cmd = "update",    ex = "clap",        color = "yellow",  desc = "Update dependencies to their latest versions" },
			{ cmd = "outdated",  ex = nil,           color = "yellow",  desc = "Show dependencies with newer versions available" },
			{ cmd = "publish",   ex = nil,           color = "yellow",  desc = "Create a PR to add your package to the registry" },
			{},
			{ cmd = "compile",   ex = nil,           color = "magenta", desc = "Compile current project into an executable" },
			{ cmd = "bundle",    ex = nil,           color = "magenta", desc = "Bundle current project into a single lua file" },
			{},
			{ cmd = "completion", ex = "bash",       color = "cyan", desc = "Print a shell completion script (bash|zsh|fish)" },
			{ cmd = "--help", pre = "<command>", color = "cyan", desc = "Print help text for command." }
		}

	ansi.printf("{blue}{bold}lde{reset} is a package manager for Lua, written in Lua. {gray}(%s)\n", currentVersion)
	ansi.printf("{bold}Usage:{reset} lde <command> {magenta}[options]")
	ansi.printf("\n{bold}Commands:{reset}")

	for _, command in ipairs(commands) do
		if not command.cmd then -- Separator
			print("")
		else
			local cmd, ex
			if command.pre then
				-- Meta rows like `<command> --help`: the placeholder sits gray in
				-- the command column, the flag takes the example column.
				cmd = ansi.format("{bold}{gray}" .. command.pre)
				ex = ansi.format("{bold}{" .. command.color .. "}" .. command.cmd)
			else
				cmd = ansi.format("{bold}{" .. command.color .. "}" .. command.cmd)
				ex = ansi.colorize("gray", command.ex or "")
			end

			ansi.printf("  %-23s %-22s %s", cmd, ex, command.desc)
		end
	end

	ansi.printf("{bold}%-25s{reset} {blue}  %s", "\nLearn more:", "https://lde.sh")
	ansi.printf("{bold}%-24s{reset} {blue}  %s", "Join the discord:", "https://lde.sh/discord")
end

---@class lde.help
---@field main fun(args?: clap.Args)
---@field forCommand fun(name: string)
local help = {
	main = main,
	forCommand = forCommand,
}

return help
