local ansi = require("ansi")
local util = require("util")

local usage = require("lde.commands.usage")

local ok, currentVersion = pcall(require, "lde.version")
currentVersion = ok and currentVersion or "0.10.0"

-- lde-core is only needed to raise the unknown-command error; load it lazily
-- so the fast help paths (bare `lde`, `lde --help`) never pay for it.
local lde = util.lazy(|| -> require("lde-core"))

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
		lde().error.raise("Unknown command " .. ansi.colorize("yellow", '"' .. name .. '"'), { hint = "Run 'lde help' to see all commands." })
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

	---@class lde.HelpCommand
	---@field cmd string? # command or placeholder text; nil marks a section separator
	---@field ex string? # example text shown in the second column
	---@field color string? # ansi color for the command column
	---@field exColor string? # overrides the default gray example color
	---@field desc string?

	---@type lde.HelpCommand[]
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
			{ cmd = "install",   ex = "rocks:tl", color = "yellow",  desc = "Install a tool to PATH with --git/--path/rocks:" },
			{ cmd = "uninstall", ex = "tl",      color = "yellow",  desc = "Uninstall a tool from PATH" },
			{ cmd = "add",       ex = "hood",        color = "yellow",  desc = "Add a dependency (--path <path> or --git <url>)" },
			{ cmd = "remove",    ex = "json",        color = "yellow",  desc = "Remove a dependency" },
			{ cmd = "tree",      ex = nil,           color = "yellow",  desc = "Show the dependency tree" },
			{ cmd = "update",    ex = "clap",        color = "yellow",  desc = "Update dependencies to their latest versions" },
			{ cmd = "outdated",  ex = nil,           color = "yellow",  desc = "Show dependencies with newer versions available" },
			{ cmd = "publish",   ex = nil,           color = "yellow",  desc = "Create a PR to add your package to the registry" },
			{ cmd = "search",    ex = "json",        color = "yellow",   desc = "Search the lde registry and luarocks" },
			{},
			{ cmd = "compile",   ex = nil,           color = "magenta", desc = "Compile current project into an executable" },
			{ cmd = "bundle",    ex = nil,           color = "magenta", desc = "Bundle current project into a single lua file" },
			{},
			{ cmd = "completion", ex = "bash",       color = "cyan", desc = "Print a shell completion script (bash|zsh|fish)" },
			{ cmd = "<command>", ex = "--help", color = "gray", exColor = "cyan", desc = "Print help text for command." }
		}

	ansi.printf("{blue}{bold}lde{reset} is a package manager for Lua, written in Lua. {gray}(%s)\n", currentVersion)
	ansi.printf("{bold}Usage:{reset} lde <command> {magenta}[options]")
	ansi.printf("\n{bold}Commands:{reset}")

	-- Column widths fit the longest command/example so the table stays
	-- compact; %-Ns pads the plain text, so the escape overhead never shifts
	-- the columns (colored and plain output line up identically).
	local cmdW, exW = 0, 0
	for _, c in ipairs(commands) do
		if c.cmd then
			cmdW = math.max(cmdW, #c.cmd)
			exW = math.max(exW, #(c.ex or ""))
		end
	end

	exW = exW + 1

	-- Breathing room between the command and example columns. The footer
	-- links pad their labels to the same total width so they line up with
	-- the descriptions.
	local gap = 2
	local linkW = cmdW + gap + exW

	for _, command in ipairs(commands) do
		if not command.cmd then -- Separator
			print("")
		else
			-- The {reset} after each cell keeps the example's color from
			-- bleeding into the description.
			ansi.printf("  {bold}{" .. command.color .. "}%-" .. cmdW .. "s{reset}" .. string.rep(" ", gap) .. "{" .. (command.exColor or "gray") .. "}%-" .. exW .. "s{reset} %s",
				command.cmd, command.ex or "", command.desc)
		end
	end

	ansi.printf("\n{bold}%-" .. linkW .. "s{reset} {blue}  %s", "Learn more:", "https://lde.sh")
	ansi.printf("{bold}%-" .. linkW .. "s{reset} {blue}  %s", "Join the discord:", "https://lde.sh/discord")
end

---@class lde.help
---@field main fun(args?: clap.Args)
---@field forCommand fun(name: string)
local help = {
	main = main,
	forCommand = forCommand,
}

return help
