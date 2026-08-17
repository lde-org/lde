local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")
local process = require("process")

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

test.it("lde add creates dependencies field when config has none", function()
	local dir = makeProject("create-dependencies-test")
	-- makeProject writes a config with dependencies = {}; overwrite it without the key
	-- so we exercise the branch that creates the field from scratch (regression:
	-- plain assignment bypassed json's keyStore and the field was dropped on encode)
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "create-dependencies-test",
		version = "0.1.0"
	}))

	ldecli({ "add", "mylib", "--path", "../mylib" }, dir)

	local config = json.decode(fs.read(path.join(dir, "lde.json")))
	test.truthy(config.dependencies, "dependencies field should be created")
	test.truthy(config.dependencies["mylib"], "mylib should be in dependencies")
	test.equal(config.dependencies["mylib"].path, "../mylib")
end)

test.it("lde add --dev --path adds to devDependencies not dependencies", function()
	local dir = makeProject("dev-path-test")
	ldecli({ "add", "mylib", "--dev", "--path", "../mylib" }, dir)

	local config = json.decode(fs.read(path.join(dir, "lde.json")))
	test.truthy(config.devDependencies, "devDependencies should exist")
	test.truthy(config.devDependencies["mylib"], "mylib should be in devDependencies")
	test.equal(config.devDependencies["mylib"].path, "../mylib")
	test.falsy(config.dependencies and config.dependencies["mylib"], "mylib should not be in dependencies")
end)

test.it("lde add --dev creates devDependencies if not present in config", function()
	local dir = makeProject("dev-create-test")
	-- makeProject writes a config with no devDependencies key
	local config = json.decode(fs.read(path.join(dir, "lde.json")))
	test.falsy(config.devDependencies, "devDependencies should not exist initially")

	ldecli({ "add", "mylib", "--dev", "--path", "../mylib" }, dir)

	local updated = json.decode(fs.read(path.join(dir, "lde.json")))
	test.truthy(updated.devDependencies, "devDependencies should be created")
	test.truthy(updated.devDependencies["mylib"], "mylib should be in devDependencies")
end)

test.it("lde add --dev --git adds git dep to devDependencies", function()
	local dir = makeProject("dev-git-test")
	ldecli({ "add", "mypkg", "--dev", "--git", "https://example.com/mypkg.git" }, dir)

	local config = json.decode(fs.read(path.join(dir, "lde.json")))
	test.truthy(config.devDependencies, "devDependencies should exist")
	test.truthy(config.devDependencies["mypkg"], "mypkg should be in devDependencies")
	test.equal(config.devDependencies["mypkg"].git, "https://example.com/mypkg.git")
	test.falsy(config.dependencies and config.dependencies["mypkg"], "mypkg should not be in dependencies")
end)

test.it("lde add --dev --git --branch stores branch in devDependencies", function()
	local dir = makeProject("dev-git-branch-test")
	ldecli({ "add", "mypkg", "--dev", "--git", "https://example.com/mypkg.git", "--branch", "main" }, dir)

	local config = json.decode(fs.read(path.join(dir, "lde.json")))
	test.truthy(config.devDependencies, "devDependencies should exist")
	local dep = config.devDependencies["mypkg"]
	test.truthy(dep, "mypkg should be in devDependencies")
	test.equal(dep.git, "https://example.com/mypkg.git")
	test.equal(dep.branch, "main")
end)

test.it("lde add --dev does not affect existing dependencies", function()
	local dir = makeProject("dev-isolation-test")
	-- Pre-populate a regular dependency
	ldecli({ "add", "existing", "--path", "../existing" }, dir)

	ldecli({ "add", "devonly", "--dev", "--path", "../devonly" }, dir)

	local config = json.decode(fs.read(path.join(dir, "lde.json")))
	test.truthy(config.dependencies["existing"], "existing dep should still be in dependencies")
	test.falsy(config.dependencies["devonly"], "devonly should not be in dependencies")
	test.truthy(config.devDependencies["devonly"], "devonly should be in devDependencies")
end)

test.it("lde add --dev removes stale lockfile entry", function()
	local dir = makeProject("dev-lockfile-test")
	fs.write(path.join(dir, "lde.lock"), json.encode({
		version = "1",
		dependencies = {
			mydevpkg = { path = "../mydevpkg" }
		}
	}))

	ldecli({ "add", "mydevpkg", "--dev", "--path", "../mydevpkg" }, dir)

	local lock = json.decode(fs.read(path.join(dir, "lde.lock")))
	test.falsy(lock.dependencies["mydevpkg"], "stale lockfile entry should be removed after lde add --dev")
end)

test.it("lde add --dev <name> resolves a registry dep into devDependencies", function()
	-- Fully offline: the fake registry's portfile points at a local repo, and
	-- `lde add` only resolves the version — the clone happens later on sync.
	local repoDir = path.join(tmpBase, "add-dev-reg-repo")
	fs.rmdir(repoDir)
	fs.mkdir(repoDir)
	fs.mkdir(path.join(repoDir, "src"))
	fs.write(path.join(repoDir, "src", "init.lua"), 'return "add-dev-reg"')
	fs.write(path.join(repoDir, "lde.json"), json.encode({
		name = "add-dev-reg",
		version = "0.1.0",
		dependencies = {}
	}))

	local treeDir = path.join(tmpBase, "add-dev-reg-tree")
	fs.rmdir(treeDir)
	fs.mkdir(treeDir)
	fs.mkdirAll(path.join(treeDir, "registry", "packages"))
	fs.write(path.join(treeDir, "registry", "packages", "add-dev-reg.json"), json.encode({
		name = "add-dev-reg",
		description = "offline test package",
		git = repoDir,
		branch = "master",
		versions = { ["1.0.0"] = "1111111", ["2.0.0"] = "2222222" }
	}))

	local dir = makeProject("add-dev-reg-test")
	local ok, out = ldecli({ "--tree", treeDir, "add", "--dev", "add-dev-reg" }, dir)
	test.truthy(ok, "lde add --dev failed: " .. tostring(out))

	local config = json.decode(fs.read(path.join(dir, "lde.json")))
	test.truthy(config.devDependencies, "devDependencies should exist")
	local dep = config.devDependencies["add-dev-reg"]
	test.truthy(dep, "add-dev-reg should be in devDependencies")
	test.equal(dep.version, "2.0.0", "latest registry version should be resolved")
	test.falsy(config.dependencies and config.dependencies["add-dev-reg"], "add-dev-reg should not be in dependencies")
	test.includes(out, "dev dependency")
end)

test.it("lde add removes the dep entry from lde.lock if present", function()
	local dir = makeProject("add-lockfile-test")
	fs.write(path.join(dir, "lde.lock"), json.encode({
		version = "1",
		dependencies = {
			mypkg = { path = "../mypkg" }
		}
	}))
	fs.mkdir(path.join(dir, "target"))
	fs.write(path.join(dir, "target", ".installed"), "stale")

	ldecli({ "add", "mypkg", "--path", "../mypkg" }, dir)

	local lockRaw = fs.read(path.join(dir, "lde.lock"))
	test.truthy(lockRaw, "lde.lock should still exist")
	local lock = json.decode(lockRaw)
	test.falsy(lock.dependencies["mypkg"], "stale lockfile entry should be removed after lde add")
	test.falsy(fs.exists(path.join(dir, "target", ".installed")), ".installed should be deleted")
end)

test.skipIf(env.var("ANDROID_ROOT") ~= nil)("lde add --git records the dep and sync pins the commit in the lockfile", function()
	-- Local repo so the whole flow is offline (lsRemote + clone on local paths).
	local repoDir = path.join(tmpBase, "add-git-repo")
	fs.rmdir(repoDir)
	fs.mkdir(repoDir)
	fs.mkdir(path.join(repoDir, "src"))
	fs.write(path.join(repoDir, "src", "init.lua"), 'return "add-git"')
	fs.write(path.join(repoDir, "lde.json"), json.encode({
		name = "addgit",
		version = "0.1.0",
		dependencies = {}
	}))
	assert(process.exec("git", { "init", "-q" }, { cwd = repoDir }), "git init failed")
	process.exec("git", { "add", "-A" }, { cwd = repoDir })
	local code = process.exec(
		"git", { "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init" },
		{ cwd = repoDir })
	assert(code == 0, "git commit failed: " .. tostring(code))

	local dir = makeProject("add-git-test")
	local ok, out = ldecli({ "add", "addgit", "--git", repoDir }, dir)
	test.truthy(ok, "lde add --git failed: " .. tostring(out))

	local config = json.decode(fs.read(path.join(dir, "lde.json")))
	test.truthy(config.dependencies["addgit"], "addgit should be in dependencies")
	test.equal(config.dependencies["addgit"].git, repoDir)

	-- The commit is auto-pinned at install time, not by add itself.
	local lockPath = path.join(dir, "lde.lock")
	if fs.exists(lockPath) then
		local lockBefore = json.decode(fs.read(lockPath))
		test.falsy(lockBefore.dependencies["addgit"], "add must not pin the commit yet")
	end

	local ok2, out2 = ldecli({ "sync" }, dir)
	test.truthy(ok2, "sync failed: " .. tostring(out2))
	local lockAfter = json.decode(fs.read(path.join(dir, "lde.lock")))
	local entry = lockAfter.dependencies["addgit"]
	test.truthy(entry and entry.commit, "commit must be auto-pinned after sync")
	test.truthy(entry.commit:match("^%x+$"), "expected a hex commit sha")
	test.truthy(fs.exists(path.join(dir, "target", "addgit", "init.lua")))
end)
