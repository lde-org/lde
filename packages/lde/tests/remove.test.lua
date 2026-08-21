local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")

local ldecli = require("tests.lib.ldecli")

local tmpBase = path.join(env.tmpdir(), "lde-remove-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

local function makeProject(name, deps, devDeps)
	local dir = path.join(tmpBase, name)
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), "")
	local conf = {
		name = name,
		version = "0.1.0",
		dependencies = deps or {}
	}
	if devDeps then conf.devDependencies = devDeps end
	fs.write(path.join(dir, "lde.json"), json.encode(conf))
	return dir
end

test.it("lde remove removes the dep from lde.json", function()
	local dir = makeProject("remove-json-test", { mypkg = { path = "../mypkg" } })

	ldecli({ "remove", "mypkg" }, dir)

	local raw = fs.read(path.join(dir, "lde.json")) ---@cast raw -nil
	local config = json.decode(raw) ---@cast config table<string, any>
	test.falsy(config.dependencies["mypkg"], "dependency should be removed from lde.json")
end)

test.it("lde remove removes the dep entry from lde.lock if present", function()
	local dir = makeProject("remove-lockfile-test", { mypkg = { path = "../mypkg" } })
	fs.write(path.join(dir, "lde.lock"), json.encode({
		version = "1",
		dependencies = {
			mypkg = { path = "../mypkg" },
			other = { path = "../other" }
		}
	}))
	fs.mkdir(path.join(dir, "target"))
	fs.write(path.join(dir, "target", ".installed"), "stale")

	ldecli({ "remove", "mypkg" }, dir)

	local lockRaw = fs.read(path.join(dir, "lde.lock"))
	test.truthy(lockRaw, "lde.lock should still exist") ---@cast lockRaw -nil
	local lock = json.decode(lockRaw) ---@cast lock table<string, any>
	test.falsy(lock.dependencies["mypkg"], "removed dep should be gone from lde.lock")
	test.truthy(lock.dependencies["other"], "unrelated lockfile entries should be preserved")
	test.falsy(fs.exists(path.join(dir, "target", ".installed")), ".installed should be deleted")
end)

test.it("lde remove removes a dev dependency from lde.json", function()
	local dir = makeProject("remove-dev-json-test", {}, { mydevpkg = { path = "../mydevpkg" } })

	ldecli({ "remove", "mydevpkg" }, dir)

	local raw = fs.read(path.join(dir, "lde.json")) ---@cast raw -nil
	local config = json.decode(raw) ---@cast config table<string, any>
	test.falsy(config.devDependencies["mydevpkg"], "dev dependency should be removed from lde.json")
	test.falsy(config.dependencies["mydevpkg"], "runtime dependencies should remain unaffected")
end)

test.it("lde remove removes the dev dep entry from lde.lock if present", function()
	local dir = makeProject("remove-dev-lockfile-test", {}, { mydevpkg = { path = "../mydevpkg" } })
	fs.write(path.join(dir, "lde.lock"), json.encode({
		version = "1",
		dependencies = {
			mydevpkg = { path = "../mydevpkg" },
			other = { path = "../other" }
		}
	}))
	fs.mkdir(path.join(dir, "target"))
	fs.write(path.join(dir, "target", ".installed"), "stale")

	ldecli({ "remove", "mydevpkg" }, dir)

	local lockRaw = fs.read(path.join(dir, "lde.lock"))
	test.truthy(lockRaw, "lde.lock should still exist") ---@cast lockRaw -nil
	local lock = json.decode(lockRaw) ---@cast lock table<string, any>
	test.falsy(lock.dependencies["mydevpkg"], "removed dev dep should be gone from lde.lock")
	test.truthy(lock.dependencies["other"], "unrelated lockfile entries should be preserved")
	test.falsy(fs.exists(path.join(dir, "target", ".installed")), ".installed should be deleted")
end)

test.it("lde remove removes a dep present in both dependencies and devDependencies", function()
	local dir = makeProject("remove-both-test", { mypkg = { path = "../mypkg" } }, { mypkg = { path = "../mypkg" } })

	ldecli({ "remove", "mypkg" }, dir)

	local raw = fs.read(path.join(dir, "lde.json")) ---@cast raw -nil
	local config = json.decode(raw) ---@cast config table<string, any>
	test.falsy(config.dependencies["mypkg"], "runtime dependency should be removed")
	test.falsy(config.devDependencies["mypkg"], "dev dependency should be removed too")
end)
