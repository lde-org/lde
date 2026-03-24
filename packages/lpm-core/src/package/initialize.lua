local path = require("path")
local fs = require("fs")
local util = require("util")
local ansi = require("ansi")
local git = require("git")

local Package = require("lpm-core.package")

local function hasGit()
	return git.version() == true
end

---@param dir string
local function isInsideGitRepo(dir)
	local ok = git.isInsideWorkTree(dir)
	return ok == true
end

--- Initializes a package at the given directory.
--- If the directory already contains an lpm.json, this will throw an error to avoid overwriting existing packages.
---@param dir string
local function initPackage(dir)
	local configPath = path.join(dir, "lpm.json")
	if fs.exists(configPath) then
		error("Directory already contains lpm.json: " .. dir)
	end

	fs.write(configPath, util.dedent([[
		{
			"name": "]] .. path.basename(dir) .. [[",
			"version": "0.1.0",
			"dependencies": {}
		}
	]]))

	local idealGitignore = util.dedent([[
		/target/
		/lpm.lock # Reserved for future use
		/lpm-lock.json
	]])

	local gitignorePath = path.join(dir, ".gitignore")
	if not fs.exists(gitignorePath) then
		fs.write(gitignorePath, idealGitignore)
	else -- Try to append to it
		local content = fs.read(gitignorePath)
		if not content then
			error("Failed to read existing .gitignore at: " .. gitignorePath)
		end

		if not string.find(content, "/target/", 1, true) then
			content = content .. "\n" .. idealGitignore
			fs.write(gitignorePath, content)
		end
	end

	local luarcPath = path.join(dir, ".luarc.json")
	if not fs.exists(luarcPath) then
		fs.write(luarcPath, util.dedent([[
			{
				"$schema": "https://raw.githubusercontent.com/sumneko/vscode-lua/master/setting/schema.json",
				"diagnostics": {
					"disable": [
						"duplicate-doc-field",
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
		local ok = git.init(dir)
		if not ok then
			ansi.printf("{yellow}Warning: failed to initialize git repository")
		end
	end

	local package = Package.open(dir)
	if not package then
		error("Failed to initialize package at directory: " .. dir)
	end

	local src = package:getSrcDir()
	if not fs.exists(src) then
		fs.mkdir(src)
		fs.write(path.join(src, "init.lua"), "print('Hello, world!')")
	end

	return package
end

return initPackage
