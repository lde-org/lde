local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")

local ldecli = require("tests.lib.ldecli")

local tmpBase = path.join(env.tmpdir(), "lde-add-tests")
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

test.it("lde add rocks:<name> stores dependency without registry prefix", function()
	local dir = makeProject("rocks-prefix-test")
	ldecli({ "add", "rocks:lpeg" }, dir)

	local config = json.decode(fs.read(path.join(dir, "lde.json")))
	test.falsy(config.dependencies["rocks:lpeg"], "dependency key should not contain 'rocks:' prefix")
	test.truthy(config.dependencies["lpeg"], "dependency should be stored as 'lpeg'")
end)
