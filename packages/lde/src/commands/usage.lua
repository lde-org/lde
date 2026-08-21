-- Central registry of per-command usage documentation. This is the single
-- source of truth for:
--
--   * `lde help <command>` / `lde --help <command>` (commands/help.lua)
--   * shell completions (commands/completion.lua, commands/complete.lua)
--
-- The table is intentionally pure data (no requires) so the completion
-- backend can load it without pulling in the rest of the CLI.

---@class lde.CommandOption
---@field arg? string # placeholder shown after the flag (e.g. "url" for --git)
---@field desc string

---@class lde.CommandSpec
---@field usage string
---@field description string
---@field arguments? string
---@field options? table<string, lde.CommandOption>

---@type table<string, lde.CommandSpec>
local commands = {
	help = {
		usage = "lde help [<command>]",
		description = "Show help for a command, or the full command list.",
		arguments = "<command>  Show detailed help for this command",
	},
	run = {
		usage = "lde run [<script>] [-- <args>...]",
		description = "Run the project's entry point (src/init.lua or bin), a named script from lde.json, or a Lua file.",
		arguments = "<script>  Entry point, script name, or path to a Lua file. Args after -- are passed to the script.",
		options = {
			["--hot"] = { desc = "Hot-reload: patch require() caches and re-run in the same state" },
			["--watch"] = { desc = "Re-run on file changes (fresh state each run)" },
			["--profile"] = { desc = "Print a flat call profile on exit" },
			["--flamegraph"] = { arg = "file", desc = "Also write a flamegraph HTML file (default: profile.html)" },
			["--json"] = { arg = "file", desc = "Also write the profile data as JSON (default: profile.json)" },
		},
	},
	x = {
		usage = "lde x <name>[@<version>] [--offline] [args...]",
		description = "Run a package from the registry, a git repo, or a local path without adding it as a dependency.",
		options = {
			["--git"] = { arg = "url", desc = "Run a package cloned from a git repository" },
			["--path"] = { arg = "dir", desc = "Run a package from a local directory" },
			["--offline"] = { desc = "Resolve from the local cache only; fail instead of updating the registry" },
		},
	},
	search = {
		usage = "lde search <query> [--all]",
		description = "Search package names and descriptions in the lde registry and on luarocks (rocks marked with a rock emoji); rocks:<query> searches luarocks only.",
		arguments = "<query>  Substring matched against package names and descriptions; rocks:<query> searches luarocks only",
		options = {
			["--all"] = { desc = "Show every match instead of the first 10 (still scrollable interactively)" },
		},
	},
	repl = {
		usage = "lde repl",
		description = "Start an interactive LuaJIT REPL in the project context.",
	},
	test = {
		usage = "lde test [<filter>...]",
		description = "Run all *.test.lua files (Teal .tl and Moonscript .moon tests are compiled first), or every package's tests when run outside a package.",
		arguments = "<filter>  Optional glob patterns limiting which test files run",
		options = {
			["--watch"] = { desc = "Re-run tests on file changes" },
			["--coverage"] = { desc = "Print a per-file line coverage report" },
			["--json"] = { arg = "file", desc = "Also write the coverage report as JSON (default: coverage.json; implies --coverage)" },
		},
	},
	new = {
		usage = "lde new [<name>] [--type <blank|library>] [--language <lua|teal|moonscript>] [--name <pkg>]",
		description = "Create a new project directory with a package skeleton. Prompts interactively for the project name, type, language, and package name; flags skip the prompts.",
		arguments = "<name>  Project name, also used as the directory name (prompted for when omitted)",
		options = {
			["--type"] = { arg = "blank|library", desc = "Scaffold a blank runnable app or a library module (default: blank)" },
			["--language"] = { arg = "lua|teal|moonscript", desc = "Entry point language; teal adds a check script and tlconfig.lua (default: lua)" },
			["--name"] = { arg = "pkg", desc = "Manifest name (default: the directory name)" },
		},
	},
	init = {
		usage = "lde init [<path>] [--type <blank|library>] [--language <lua|teal|moonscript>] [--name <pkg>]",
		description = "Initialize a directory as an lde project (defaults to the current directory). Prompts for project type, language, and package name interactively, unless flags are given.",
		arguments = "<path>  Directory to initialize (default: current directory)",
		options = {
			["--type"] = { arg = "blank|library", desc = "Scaffold a blank runnable app or a library module (default: blank)" },
			["--language"] = { arg = "lua|teal|moonscript", desc = "Entry point language; teal adds a check script and tlconfig.lua (default: lua)" },
			["--name"] = { arg = "pkg", desc = "Manifest name (default: the directory name)" },
		},
	},
	upgrade = {
		usage = "lde upgrade",
		description = "Upgrade lde to the latest version.",
		options = {
			["--force"] = { desc = "Upgrade even when already on the latest version" },
			["--nightly"] = { desc = "Upgrade to the nightly build" },
			["--version"] = { arg = "version", desc = "Upgrade to a specific version" },
		},
	},
	sync = {
		usage = "lde sync",
		description = "Install the project's dependencies.",
		options = {
			["--locked"] = { desc = "Install only what is recorded in the lockfile" },
			["--production"] = { desc = "Skip dev dependencies" },
		},
	},
	install = {
		usage = "lde install [<name>[@<version>]]",
		description = "Install the current project's dependencies, or install a tool to PATH via --git, --path, or rocks:.",
		options = {
			["--git"] = { arg = "url", desc = "Install a tool from a git repository" },
			["--path"] = { arg = "dir", desc = "Install a tool from a local directory" },
			["--production"] = { desc = "Skip dev dependencies" },
		},
	},
	uninstall = {
		usage = "lde uninstall <name>",
		description = "Uninstall a tool from PATH.",
		arguments = "<name>  Name of the installed tool",
	},
	add = {
		usage = "lde add <name>[@<version>] [--git <url> | --path <dir>]",
		description = "Add a dependency to lde.json. Always use this instead of editing the manifest by hand, so the lockfile stays in sync.",
		options = {
			["--dev"] = { desc = "Add to devDependencies" },
			["--git"] = { arg = "url", desc = "Add a git dependency (commit auto-pinned)" },
			["--path"] = { arg = "dir", desc = "Add a local path dependency" },
			["--branch"] = { arg = "branch", desc = "With --git: use a specific branch" },
			["--commit"] = { arg = "sha", desc = "With --git: pin a specific commit" },
			["--version"] = { arg = "version", desc = "Pin a registry dependency version" },
		},
	},
	remove = {
		usage = "lde remove <name>",
		description = "Remove a dependency from lde.json.",
		arguments = "<name>  Dependency key to remove",
	},
	tree = {
		usage = "lde tree",
		description = "Show the dependency tree.",
	},
	update = {
		usage = "lde update [<name>]",
		description = "Update dependencies to their latest versions.",
		arguments = "<name>  Only update this dependency",
	},
	outdated = {
		usage = "lde outdated",
		description = "Show dependencies with newer versions available.",
	},
	publish = {
		usage = "lde publish",
		description = "Create a PR to add your package to the registry.",
	},
	compile = {
		usage = "lde compile [--outfile <path>]",
		description = "Compile the current project into a single executable.",
		options = {
			["--outfile"] = { arg = "path", desc = "Output path (defaults to ./<project-name>)" },
		},
	},
	bundle = {
		usage = "lde bundle [--outfile <path>] [--bytecode]",
		description = "Bundle the current project into a single Lua file.",
		options = {
			["--outfile"] = { arg = "path", desc = "Output path (defaults to ./<name>.lua)" },
			["--bytecode"] = { desc = "Precompile bundled modules to bytecode" },
		},
	},
	completion = {
		usage = "lde completion <bash|zsh|fish>",
		description = "Print a shell completion script. Add it to your shell rc, e.g. eval \"$(lde completion bash)\".",
		arguments = "<shell>  One of: bash, zsh, fish",
	},
}

---@type table<string, string> # alias -> canonical command
local aliases = {
	i = "install",
}

-- Global flags that make sense anywhere (shown in per-command help and offered
-- after a command by the completions).
---@type table<string, lde.CommandOption>
local globalFlags = {
	["--help"] = { desc = "Show help" },
	["--version"] = { desc = "Show the lde version" },
	["-v"] = { desc = "Show the lde version (alias for --version)" },
	["--cwd"] = { arg = "dir", desc = "Change working directory before running" },
	["-C"] = { arg = "dir", desc = "Change working directory (alias for --cwd)" },
	["--tree"] = { arg = "dir", desc = "Use <dir> as the global lde directory" },
}

-- Global flags that only make sense before a command.
---@type table<string, lde.CommandOption>
local topLevelFlags = {
	["--lua"] = { desc = "Run the lde binary as a plain Lua interpreter" },
	["-e"] = { arg = "code", desc = "Run a Lua expression in the project context" },
	["--setup"] = { desc = "Set up PATH and install helper binaries" },
	["--update-path"] = { desc = "Add lde's directories to PATH" },
	["--ensure-mingw"] = { desc = "Install the MinGW toolchain (Windows)" },
}

-- Flags whose value is a directory (shells complete directories for these).
local dirFlags = { "-C", "--cwd", "--tree", "--path" }

-- Flags whose value is a file path.
local fileFlags = { "--outfile" }

-- Flags that take a value: completion suppresses suggestions for the value
-- position (shells handle the common cases listed above).
local valueFlags = { "-C", "--cwd", "--tree", "--path", "--git", "--branch", "--commit", "--version", "--outfile", "--flamegraph", "--type", "--language", "--name" }

-- Canonical command names in display order.
local names = { "help", "run", "x", "search", "repl", "test", "new", "init", "upgrade", "sync", "install", "uninstall", "add", "remove", "tree", "update", "outdated", "publish", "compile", "bundle", "completion" }

-- Every name the completions may offer, including aliases.
local completionNames = {}
for _, name in ipairs(names) do
	completionNames[#completionNames + 1] = name
end
for alias in pairs(aliases) do
	completionNames[#completionNames + 1] = alias
end
table.sort(completionNames)

return {
	commands = commands,
	aliases = aliases,
	globalFlags = globalFlags,
	topLevelFlags = topLevelFlags,
	dirFlags = dirFlags,
	fileFlags = fileFlags,
	valueFlags = valueFlags,
	names = names,
	completionNames = completionNames,
}
