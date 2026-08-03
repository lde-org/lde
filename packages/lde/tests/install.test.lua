local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")

local ldecli = require("tests.lib.ldecli")

local tmpBase = path.join(env.tmpdir(), "lde-install-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

local function makeProject(name)
	local dir = path.join(tmpBase, name)
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), "")
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = name,
		version = "0.1.0",
		dependencies = {}
	}))
	return dir
end

test.it("reinstalls src.rock correctly after tar cache and target are cleared (lde.lock retained)", function()
	local dir = makeProject("srcrock-reinstall-test")
	fs.write(path.join(dir, "src", "init.lua"), 'print(require("socket"))')

	local ok, out = ldecli({ "add", "rocks:luasocket" }, dir)
	test.truthy(ok, "lde add failed: " .. tostring(out))

	local home = os.getenv("HOME") or os.getenv("USERPROFILE")
	fs.rmdir(path.join(home, ".lde", "tar"))
	fs.rmdir(path.join(dir, "target"))

	ok, out = ldecli({ "run" }, dir)
	test.truthy(ok, "lde run failed after cache clear: " .. tostring(out))
end)
