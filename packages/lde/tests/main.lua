local test = require("lde-test")

local process = require("process")
local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")
local git = require("git")

local lde = require("lde-core")

local ldePath = assert(env.execPath())

---@param args string[]
local function ldecli(args)
	return process.exec(ldePath, args)
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
