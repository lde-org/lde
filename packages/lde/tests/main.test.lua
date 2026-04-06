local test = require("lde-test")

local process = require("process2")
local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")
local git = require("git")

local lde = require("lde-core")

local ldePath = assert(env.execPath())

---@param args string[]
local function ldecli(args)
	local code, stdout, stderr = process.exec(ldePath, args)
	return code == 0, stdout or stderr
end

test.it("should not ignore --git in ldx", function()
	-- Pre-populate the git cache so no real clone happens
	local repoDir = lde.global.getGitRepoDir("hood")
	fs.rmdir(repoDir)
	fs.mkdir(repoDir)
	git.init(repoDir, true)
	fs.write(path.join(repoDir, "lde.json"), json.encode({
		name = "hood",
		version = "1.0.0",
		dependencies = {}
	}))
	fs.mkdir(path.join(repoDir, "src"))
	fs.write(path.join(repoDir, "src", "init.lua"), "")

	local _, out = ldecli { "x", "triangle", "--git", "https://github.com/codebycruz/hood" }
	test.falsy(out:find("not found in lde registry"))
	test.includes(out, "No package named 'triangle'")

	fs.rmdir(repoDir)
end)

test.it("--tree overrides the global lde directory", function()
	local tmpTree = path.join(env.tmpdir(), "lde-tree-test")
	fs.rmdir(tmpTree)

	ldecli { "--tree", tmpTree, "--version" }

	test.truthy(fs.exists(tmpTree))
	test.truthy(fs.exists(path.join(tmpTree, "git")))
end)