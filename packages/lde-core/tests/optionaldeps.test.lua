local test = require("lde-test")

local lde = require("lde-core")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")

local tmpBase = path.join(env.tmpdir(), "lde-optionaldeps-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

-- Create three dummy platform-specific packages
local platforms = { "linux-dep", "windows-dep", "macos-dep" }
for _, name in ipairs(platforms) do
	local dir = path.join(tmpBase, name)
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), 'return "' .. name .. '"')
	fs.write(path.join(dir, "lde.json"), json.encode({ name = name, version = "0.1.0" }))
end

-- Consumer with all three as optional deps, each gated behind its platform feature
local appDir = path.join(tmpBase, "consumer")
fs.mkdir(appDir)
fs.write(path.join(appDir, "lde.json"), json.encode({
	name = "consumer",
	version = "0.1.0",
	dependencies = {
		["linux-dep"]   = { path = "../linux-dep",   optional = true },
		["windows-dep"] = { path = "../windows-dep", optional = true },
		["macos-dep"]   = { path = "../macos-dep",   optional = true },
	},
	features = {
		linux   = { "linux-dep" },
		windows = { "windows-dep" },
		macos   = { "macos-dep" },
	}
}))

test.it("optional deps: only the current platform dep is installed", function()
	local app = lde.Package.open(appDir)
	app:installDependencies()

	local targetDir = app:getModulesDir()
	local osDep = {
		Linux   = "linux-dep",
		Windows = "windows-dep",
		OSX     = "macos-dep",
	}

	local expected = osDep[jit.os]
	local unexpected = {}
	for _, name in ipairs(platforms) do
		if name ~= expected then
			unexpected[#unexpected + 1] = name
		end
	end

	test.truthy(fs.exists(path.join(targetDir, expected)),
		"expected " .. expected .. " to be installed for " .. jit.os)

	for _, name in ipairs(unexpected) do
		test.falsy(fs.exists(path.join(targetDir, name)),
			"expected " .. name .. " NOT to be installed on " .. jit.os)
	end
end)
