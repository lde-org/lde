const test = require("lde-test")

const lde = require("lde-core")

const fs = require("fs")
const env = require("env")
local path = require("path")
const json = require("json")

local tmpBase = path.join(env.tmpdir(), "lde-optionaldeps-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

const platforms = { "linux-dep", "windows-dep", "macos-dep" }
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

const osDep = { Linux = "linux-dep", Windows = "windows-dep", OSX = "macos-dep" }

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
	const lockfile = lde.Lockfile.open(app:getLockfilePath())
	test.truthy(lockfile) ---@cast lockfile -nil
	for _, name in ipairs(platforms) do
		const entry = lockfile:getDependency(name)
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

-- A dependency installed by an earlier install and not wanted by this one is removed from
-- target/, so it can't end up in a bundle: switching to an Android target, or dropping it from
-- lde.json. The source a path dependency links to is never touched.
const features = require("lde-core.package.features")
const sea = require("sea")

local androidDir = path.join(tmpBase, "android-dep")
fs.mkdir(androidDir)
fs.mkdir(path.join(androidDir, "src"))
fs.write(path.join(androidDir, "src", "init.lua"), 'return "android-dep"')
fs.write(path.join(androidDir, "lde.json"), json.encode({ name = "android-dep", version = "0.1.0" }))

local backendsDir = path.join(tmpBase, "backends")
fs.mkdir(backendsDir)
fs.write(path.join(backendsDir, "lde.json"), json.encode({
	name = "backends",
	version = "0.1.0",
	dependencies = {
		["linux-dep"]   = { path = "../linux-dep",   optional = true },
		["windows-dep"] = { path = "../windows-dep", optional = true },
		["macos-dep"]   = { path = "../macos-dep",   optional = true },
		["android-dep"] = { path = "../android-dep", optional = true },
	},
	features = {
		linux   = { "linux-dep" },
		windows = { "windows-dep" },
		macos   = { "macos-dep" },
		android = { "android-dep" },
	}
}))

---@param fn fun()
local function withAndroidTarget(fn)
	const target = assert(sea.getTarget("android-x86-64-apk"))
	lde.global.setTarget(target)
	features.setTarget(target)
	local ok, err = pcall(fn)
	lde.global.setTarget(nil)
	features.setTarget(nil)
	if not ok then error(err, 0) end
end

test.it("optional deps: switching to an Android target removes the desktop backend from target/", function()
	local app = lde.Package.open(backendsDir) ---@cast app -nil
	const targetDir = app:getModulesDir()
	const hostDep = osDep[jit.os]

	app:installDependencies()
	test.truthy(fs.exists(path.join(targetDir, hostDep)), "host backend installed first")

	withAndroidTarget(function() app:installDependencies() end)
	test.truthy(fs.exists(path.join(targetDir, "android-dep")), "the Android backend is installed")
	test.falsy(fs.exists(path.join(targetDir, hostDep)), "the host backend is gone from target/")
	test.truthy(fs.exists(path.join(tmpBase, hostDep, "src", "init.lua")), "its source is untouched")

	app:installDependencies()
	test.truthy(fs.exists(path.join(targetDir, hostDep)), "switching back brings it back")
	test.falsy(fs.exists(path.join(targetDir, "android-dep")))
end)

test.it("deps: a dependency removed from lde.json is removed from target/, dev deps are kept", function()
	local dir = path.join(tmpBase, "dropper")
	fs.mkdir(dir)
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "dropper",
		version = "0.1.0",
		dependencies = { ["linux-dep"] = { path = "../linux-dep" } },
		devDependencies = { ["macos-dep"] = { path = "../macos-dep" } },
	}))
	local app = lde.Package.open(dir) ---@cast app -nil
	app:installDependencies()
	app:installDevDependencies()
	test.truthy(fs.exists(path.join(app:getModulesDir(), "linux-dep")))
	test.truthy(fs.exists(path.join(app:getModulesDir(), "macos-dep")))

	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "dropper",
		version = "0.1.0",
		dependencies = { ["windows-dep"] = { path = "../windows-dep" } },
		devDependencies = { ["macos-dep"] = { path = "../macos-dep" } },
	}))
	app = lde.Package.open(dir) ---@cast app -nil
	app:installDependencies()

	test.truthy(fs.exists(path.join(app:getModulesDir(), "windows-dep")))
	test.falsy(fs.exists(path.join(app:getModulesDir(), "linux-dep")), "the dropped dependency is gone")
	test.truthy(fs.exists(path.join(app:getModulesDir(), "macos-dep")), "the dev dependency is kept")
end)
