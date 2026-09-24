local test = require("lde-test")

local lde = require("lde-core")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")

local tmpBase = path.join(env.tmpdir(), "lde-optionaldeps-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

local platforms = { "linux-dep", "windows-dep", "macos-dep" }
for _, name in ipairs(platforms) do
	local dir = path.join(tmpBase, name)
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), 'return "' .. name .. '"')
	fs.write(path.join(dir, "lde.json"), json.encode({ name = name, version = "0.1.0" }))
end

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

local osDep = { Linux = "linux-dep", Windows = "windows-dep", OSX = "macos-dep" }

test.it("optional deps: only the current platform dep is installed", function()
	local app = lde.Package.open(appDir) ---@cast app -nil
	app:installDependencies()

	local targetDir = app:getModulesDir()
	local expected = osDep[jit.os]

	test.truthy(fs.exists(path.join(targetDir, expected)))
	for _, name in ipairs(platforms) do
		if name ~= expected then
			test.falsy(fs.exists(path.join(targetDir, name)))
		end
	end
end)

test.it("optional deps: lockfile preserves optional flag", function()
	local app = lde.Package.open(appDir) ---@cast app -nil
	local lockfile = lde.Lockfile.open(app:getLockfilePath())
	test.truthy(lockfile) ---@cast lockfile -nil
	for _, name in ipairs(platforms) do
		local entry = lockfile:getDependency(name)
		test.truthy(entry) ---@cast entry -nil
		test.truthy(entry.optional)
	end
end)

test.it("optional deps: still respected on second install (lockfile path)", function()
	local app = lde.Package.open(appDir) ---@cast app -nil
	fs.rmdir(app:getModulesDir())
	app:installDependencies()

	local targetDir = app:getModulesDir()
	local expected = osDep[jit.os]

	test.truthy(fs.exists(path.join(targetDir, expected)))
	for _, name in ipairs(platforms) do
		if name ~= expected then
			test.falsy(fs.exists(path.join(targetDir, name)))
		end
	end
end)

-- A package in the middle of the graph gates its own optional deps the same way the
-- root does: the platform's flag is every package's, not just the one being installed.
-- This is the case that does not fail a build when it is wrong -- the other platform's
-- dependency is simply installed, and with it shipped, for a platform it cannot run on.
local middleDir = path.join(tmpBase, "middle")
fs.mkdir(middleDir)
fs.mkdir(path.join(middleDir, "src"))
fs.write(path.join(middleDir, "src", "init.lua"), 'return "middle"')
fs.write(path.join(middleDir, "lde.json"), json.encode({
	name = "middle",
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

local viaDir = path.join(tmpBase, "via")
fs.mkdir(viaDir)
fs.write(path.join(viaDir, "lde.json"), json.encode({
	name = "via",
	version = "0.1.0",
	dependencies = { middle = { path = "../middle" } },
}))

test.it("optional deps: a dependency's own optional deps are gated by its platform too", function()
	local app = lde.Package.open(viaDir) ---@cast app -nil
	app:installDependencies()

	local targetDir = app:getModulesDir()
	local expected = osDep[jit.os]

	test.truthy(fs.exists(path.join(targetDir, "middle")), "the package in the middle is installed")
	test.truthy(fs.exists(path.join(targetDir, expected)))

	for _, name in ipairs(platforms) do
		if name ~= expected then
			test.falsy(fs.exists(path.join(targetDir, name)), name .. " is not installed, as it is not this platform's")
		end
	end
end)
