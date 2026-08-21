local path = require("path")
local fs = require("fs")
local util = require("util")
local ansi = require("ansi")

local lde = require("lde-core")

local git2 = util.lazy(|| -> require("git2-sys"))

local Package = require("lde-core.package")

local function hasGit()
	return true
end

---@type string
local AGENT_TEMPLATE = util.dedent([[
# Building Projects with lde

`lde` is a package manager and toolkit for Lua (LuaJIT). It manages project-local dependencies, runs Lua programs, runs tests, and compiles projects into single executables.

## Quick Reference

```sh
lde run                     # build + install deps + run entry point (src/init.lua)
lde test                    # run all **/*.test.lua files (.tl/.moon compiled first)
lde compile                 # compile to a single native executable
lde bundle                  # bundle into a single .lua file
lde -e "<code>"             # run a one-liner with project deps available
lde ./path/to/file.lua      # run an arbitrary file with project deps available

lde add <alias> --path ../pkg       # add a local path dependency
lde add <alias> --git <url>         # add a git dependency (commit auto-pinned)
lde add <alias>@<version>           # add a registry dependency
lde remove <alias>                  # remove a dependency
```

**Always use `lde add`/`lde remove`** — never edit `lde.json` by hand or the lockfile goes out of sync.

Dependency installation happens automatically on `lde run`, `lde test`, and `lde compile`. If an external runtime (e.g. LOVE2D) runs your code, use `lde sync` to populate `target/`.

## Project Structure

```
├── lde.json          # package manifest — dependencies, scripts, hasMetadata
├── lde.lock          # lockfile — commit this
├── src/
│   └── init.lua      # default entry point
├── tests/            # test files (**/*.test.lua, .tl/.moon welcome)
├── build.lua         # (optional) custom build script
└── target/           # build output — NEVER commit this
```

## The Manifest (`lde.json`)

```jsonc
{
  "name": "my-package",
  "version": "0.1.0",
  "bin": "src/main.lua",          // optional entry point override (default: src/init.lua)
  "engine": "lde",                // "lde" (default), "lua", or "luajit"
  "scripts": {
    "build": "echo building..."   // runnable via `lde run build`
  },
  "dependencies": {
    "json":    { "path": "../json" },                           // local path
    "hood":    { "git": "https://github.com/user/hood" },       // git
    "semver":  { "version": "1.0.0" },                         // registry
    "mylib":   { "luarocks": "luafilesystem" },                // LuaRocks
    "winapi":  { "git": "...", "optional": true }              // optional (feature-gated)
  },
  "devDependencies": {
    "lde-test": { "version": "1.0.0" }
  },
  "features": {
    "windows": ["winapi"]
  }
}
```

Platform features (`windows`, `linux`, `macos`, `android`) are auto-detected. Optional deps listed under the current platform are installed automatically.

`lde-test` and `lde-build` are included with the lde runtime — adding them to `devDependencies` is only needed for LSP typings.

## How `require()` Resolution Works

`lde run` and `lde test` set `package.path` / `package.cpath` to point at `target/`:

```
target/?.lua
target/?/init.lua
target/?.so       (or .dll / .dylib)
```

Dependencies are installed as symlinks at `target/<alias>`. **The require name is the key in `dependencies`, not the package's `name` field.** This means you can alias packages by choosing a different key.

During `lde test`, the project's `tests/` directory is exposed as `target/tests`, so test files can share helpers:

```lua
-- tests/foo.test.lua
local helper = require("tests.lib.helper")  -- resolves to tests/lib/helper.lua
```

Your own source is built into `target/<name>/` before `lde test` runs, so tests
reach your modules by **package name** — the same alias rule as dependencies.
The require name is the `name` field in `lde.json`, never `src`:

```lua
-- src/mathlib.lua defines M; the package name is "my-package"
-- tests/mathlib.test.lua
local mathlib = require("my-package.mathlib")  -- resolves to src/mathlib.lua
```

## Testing

```sh
lde test                    # run all **/*.test.lua in the package
lde test -- path/to/test    # run a specific test file
```

Test files must match `**/*.test.lua` — Teal (`.tl`) and Moonscript (`.moon`) test files are supported and compiled to Lua before running, the same way `lde run` compiles `src/`:

```lua
local test = require("lde-test")

test.it("describes the test", function()
  test.equal(actual, expected)
  test.notEqual(a, b)
  test.truthy(x)
  test.falsy(x)
  test.deepEqual(t1, t2)         -- recursive deep equality (including metatables)
  test.match(actual, expected)    -- subset match (like jest toMatchObject)
  test.includes(haystack, needle) -- string contains substring
  test.greater(a, b)              -- a > b
  test.less(a, b)                 -- a < b
  test.greaterEqual(a, b)         -- a >= b
  test.lessEqual(a, b)            -- a <= b
  test.count(tbl)                 -- returns number of keys (via pairs)
end)

test.skip("pending test", function() ... end)
test.skipIf(condition)("conditionally skipped", function() ... end)
test.afterEach(function() ... end)  -- runs after each test
test.afterAll(function() ... end)   -- runs once after all tests
```

Every assertion takes an optional trailing context message, appended to the failure output.

## Compiling

```sh
lde compile     # compile to a single native executable
lde bundle      # bundle into a single .lua file (no embedded runtime)
```

`lde compile` produces a self-contained binary that bundles your code, all dependencies, and the LuaJIT runtime.

## Build Scripts (`build.lua`)

If a package has a `build.lua` at its root, lde executes it instead of symlinking `src/`. **Always use the `lde-build` API** — it handles cross-platform behavior and provides fetch/extract without requiring any tools beyond lde on the user's machine.

```lua
local build = require("lde-build")

-- Network (no curl/wget needed)
local body = build:fetch(url)           -- HTTP GET, returns body string

-- File I/O (all paths relative to output dir at target/<name>)
build:write("filename.lua", content)    -- write file
local content = build:read("f")         -- read file
build:copy("src", "dst")                -- copy file or directory
build:move("src", "dst")                -- move/rename
build:delete("path")                    -- delete file or directory
build:exists("path")                    -- returns bool
build:extract("archive.zip", "dest/")   -- extract zip/tar (no tar/unzip needed)

-- Shell
build:sh("gcc -shared -o lib.o src.c") -- run command, asserts exit code 0
```

The env var `LDE_OUTPUT_DIR` is also set to the output path.

## Useful Built-in Libraries

| Package | Purpose |
|---------|---------|
| `fs` | Filesystem operations (read, write, copy, move, mkdir, scan, stat) |
| `path` | Path manipulation (join, basename, dirname, resolve, relative) |
| `env` | Environment (get/set vars, cwd, executable path) |
| `process` | Subprocess execution |
| `json` | JSON encode/decode |
| `ansi` | Colored terminal output |
| `clap` | CLI argument parsing |

Add them with: `lde add <name> --git https://github.com/lde-org/<name>`

## Lockfile

`lde.lock` pins exact versions, commits, and hashes. **Always commit it.** `target/` is build output — **never commit it.**

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `module 'x' not found` | Run `lde run` — it auto-installs deps. Verify the require name matches the key in `lde.json` `dependencies`. |
| `module 'src.foo' not found` in a test | Your own source is reachable by package name: `require("<name>.foo")` (the `name` field in `lde.json`), not `require("src.foo")`. |
| Stale dependencies / changes not taking effect | Delete `target/` and `lde.lock`, then re-run. |
| Global cache may be corrupted | Delete `~/.lde/git` and/or `~/.lde/tar` to clear isCached downloads. |
| Build script failing | `build:sh()` asserts exit code 0 — wrap in `pcall` if failures are expected. |
| Tests not found | Test files must match `**/*.test.lua`. They must be in the `tests/` directory. |
]])

--- Check whether a binary exists on PATH. Scans PATH directly instead of
--- spawning a subprocess: `command -v` is a shell builtin, so execvp can't
--- find it on minimal systems (CI runners), and checking seven agents with
--- `where`/`command` subprocesses per Package.init is needlessly slow.
---@param name string
local function hasBinary(name)
	local pathVar = os.getenv("PATH") or ""
	local sep = jit.os == "Windows" and ";" or ":"
	for dir in pathVar:gmatch("[^" .. sep .. "]+") do
		if dir ~= "" then
			local base = path.join(dir, name)
			if jit.os == "Windows" then
				if fs.exists(base) or fs.exists(base .. ".exe")
					or fs.exists(base .. ".cmd") or fs.exists(base .. ".bat") then
					return true
				end
			else
				local stat = fs.stat(base)
				if stat and (stat.mode ?? 0) & 0x49 ~= 0 then -- any exec bit
					return true
				end
			end
		end
	end
	return false
end

---@param dir string
local function isInsideGitRepo(dir)
	local current = dir
	while current do
		local repo = git2().open(current)
		if repo then
			if repo:workdir() ~= nil then return true end
		end
		local parent = path.dirname(current)
		if parent == current then break end
		current = parent
	end

	return false
end

---@class lde.Package.InitOptions
---@field type "blank"|"library"? # blank = runnable hello-world app (default), library = module entry point
---@field language "lua"|"teal"|"moonscript"? # default "lua"; teal adds a `check` script and tlconfig.lua
---@field name string? # manifest name override (default: directory basename)

---@param projectType "blank"|"library"
---@param language "lua"|"teal"|"moonscript"
---@return string
local function entryContent(projectType, language)
	if projectType == "library" then
		if language == "teal" then
			return util.dedent([[
				local M = {}

				---Greets a name with a friendly message.
				function M.greet(name: string): string
					return "Hello, " .. name .. "!"
				end

				return M
			]])
		elseif language == "moonscript" then
			return util.dedent([[
				M = {}

				-- Greets a name with a friendly message.
				M.greet = (name) -> "Hello, " .. name .. "!"

				return M
			]])
		else
			return util.dedent([[
				local M = {}

				---Greets a name with a friendly message.
				---@param name string
				---@return string
				function M.greet(name)
					return "Hello, " .. name .. "!"
				end

				return M
			]])
		end
	end

	if language == "teal" then
		return util.dedent([[
			local name: string = "world"
			print("Hello, " .. name .. "!")
		]])
	elseif language == "moonscript" then
		return util.dedent([[
			print "Hello, world!"
		]])
	end

	return "print('Hello, world!')"
end

--- Write a scaffold file as a proper POSIX text file: guaranteed trailing
--- newline (a missing one trips `git diff --check` and other tooling).
---@param p string
---@param content string
local function writeText(p, content)
	if content:sub(-1) ~= "\n" then content = content .. "\n" end
	fs.write(p, content)
end

--- Initializes a package at the given directory.
--- If the directory already contains an lde.json, this will throw an error to avoid overwriting existing packages.
---@param dir string
---@param opts lde.Package.InitOptions?
local function initPackage(dir, opts)
	opts = opts or {}

	local projectType = opts.type or "blank"
	if projectType ~= "blank" and projectType ~= "library" then
		lde.error.raise("Unknown project type: " .. projectType .. " (expected 'blank' or 'library')")
	end

	local language = opts.language or "lua"
	if language ~= "lua" and language ~= "teal" and language ~= "moonscript" then
		lde.error.raise("Unknown language: " .. language .. " (expected 'lua', 'teal', or 'moonscript')")
	end

	local packageName = path.basename(dir)
	if opts.name and opts.name ~= "" then
		packageName = opts.name --[[@as string]]
		if packageName:find("[%s/\\]") then
			lde.error.raise("Invalid package name: '" .. packageName .. "' (no spaces or path separators)")
		end
	end
	if packageName == "tests" then
		lde.error.raise("The name 'tests' is reserved for the test fixtures directory (target/tests during lde test); choose another name")
	end

	local configPath = path.join(dir, "lde.json")
	if fs.exists(configPath) then
		lde.error.raise("Directory already contains lde.json: " .. dir)
	end

	if not fs.isdir(dir) then
		fs.mkdir(dir)
	end

	-- One tab of indentation per JSON nesting level, root brace unindented —
	-- the same shape the json encoder produces (see lde add rewriting lde.json).
	local configLines = {
		"{",
		'\t"name": "' .. packageName .. '",',
		'\t"version": "0.1.0",',
	}
	if language == "teal" then
		configLines[#configLines + 1] = '\t"scripts": {'
		configLines[#configLines + 1] = '\t\t"check": "tl check -I target src/init.tl"'
		configLines[#configLines + 1] = '\t},'
	end
	configLines[#configLines + 1] = '\t"dependencies": {}'
	configLines[#configLines + 1] = '}'
	writeText(configPath, table.concat(configLines, "\n"))

	local idealGitignore = util.dedent([[
		/target/
	]])

	local gitignorePath = path.join(dir, ".gitignore")
	if not fs.exists(gitignorePath) then
		writeText(gitignorePath, idealGitignore)
	else -- Try to append to it
		local content = fs.read(gitignorePath)
		if not content then
			lde.error.raise("Failed to read existing .gitignore at: " .. gitignorePath)
		end ---@cast content -nil

		if not string.find(content, "/target/", 1, true) then
			content = content .. "\n" .. idealGitignore
			writeText(gitignorePath, content)
		end
	end

	if language == "teal" then
		local tlconfigPath = path.join(dir, "tlconfig.lua")
		if not fs.exists(tlconfigPath) then
			writeText(tlconfigPath, util.dedent([[
				return {
					include_dir = { "target" },
				}
			]]))
		end
	end

	local luarcPath = path.join(dir, ".luarc.json")
	if not fs.exists(luarcPath) then
		writeText(luarcPath, util.dedent([[
			{
				"$schema": "https://raw.githubusercontent.com/sumneko/vscode-lua/master/setting/schema.json",
				"diagnostics": {
					"disable": [
						"duplicate-doc-field",
						"duplicate-index",
						"duplicate-set-field",
						"duplicate-doc-alias"
					]
				},
				"runtime": {
					"version": "LuaJIT",
					"path": ["./target/?.lua", "./target/?/init.lua"]
				},
				"workspace": {
					"library": ["target"]
				}
			}
		]]))
	end

	if hasGit() and not isInsideGitRepo(dir) then
		local repo = git2().init(dir)
		if not repo then
			ansi.printf("{yellow}Warning: failed to initialize git repository")
		end
	end

	local package = Package.open(dir)
	if not package then
		lde.error.raise("Failed to initialize package at directory: " .. dir)
	end ---@cast package -nil

	local src = package:getSrcDir()
	if not fs.exists(src) then
		local entryFile = language == "teal" and "init.tl"
			or language == "moonscript" and "init.moon"
			or "init.lua"

		fs.mkdir(src)
		writeText(path.join(src, entryFile), entryContent(projectType, language))
	end

	-- Write agent instructions if a known coding agent is present. claude reads
	-- CLAUDE.md; every other supported harness reads AGENTS.md, which is
	-- preferred when several agents are installed.
	local agentFile
	for _, agent in ipairs({ "opencode", "dsh", "pi", "zed", "gemini", "codex", "reasonix" }) do
		if hasBinary(agent) then
			agentFile = "AGENTS.md"
			break
		end
	end
	if not agentFile and hasBinary("claude") then
		agentFile = "CLAUDE.md"
	end
	if agentFile then
		writeText(path.join(dir, agentFile), AGENT_TEMPLATE)
	end

	return package
end

return initPackage
