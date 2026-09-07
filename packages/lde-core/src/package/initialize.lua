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
# Using lde

This project is built using lde. Read https://lde.sh/llms.txt for everything you need
to know about building, running, handling dependencies and running tests.
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
		configLines[#configLines + 1] = '\t\t"check": "ldx rocks:tl check -I target src/init.tl"'
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

	-- .luarc.json configures lua-language-server, which only understands Lua
	-- sources — skip it for Teal and Moonscript projects. Never touch an
	-- existing file.
	if language == "lua" then
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
