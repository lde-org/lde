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

--- Create a local git repo with one commit, usable as an offline --git source
--- (lsRemote + clone both work on local paths). Returns the repo dir.
---@param name string # repo dir name
---@param pkgName string? # package name in the repo's lde.json (defaults to name)
---@return string
local function makeGitRepo(name, pkgName)
	local repoDir = path.join(tmpBase, name)
	fs.rmdir(repoDir)
	fs.mkdir(repoDir)
	fs.mkdir(path.join(repoDir, "src"))
	fs.write(path.join(repoDir, "src", "init.lua"), 'return "from ' .. name .. '"')
	fs.write(path.join(repoDir, "lde.json"), json.encode({
		name = pkgName or name,
		version = "0.1.0",
		dependencies = {}
	}))
	assert(process.exec("git", { "init", "-q" }, { cwd = repoDir }), "git init failed")
	process.exec("git", { "add", "-A" }, { cwd = repoDir })
	local code = process.exec(
		"git", { "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init" },
		{ cwd = repoDir })
	assert(code == 0, "git commit failed: " .. tostring(code))
	return repoDir
end

test.it("lde add rocks:<name> stores dependency without registry prefix", function()
	local dir = makeProject("rocks-prefix-test")
	ldecli({ "add", "rocks:lpeg" }, dir)

	local raw = fs.read(path.join(dir, "lde.json")) ---@cast raw -nil
	local config = json.decode(raw) ---@cast config table<string, any>
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

	local raw = fs.read(path.join(dir, "lde.json")) ---@cast raw -nil
	local config = json.decode(raw) ---@cast config table<string, any>
	test.truthy(config.dependencies, "dependencies field should be created")
	test.truthy(config.dependencies["mylib"], "mylib should be in dependencies")
	test.equal(config.dependencies["mylib"].path, "../mylib")
end)

test.it("lde add --dev --path adds to devDependencies not dependencies", function()
	local dir = makeProject("dev-path-test")
	ldecli({ "add", "mylib", "--dev", "--path", "../mylib" }, dir)

	local raw = fs.read(path.join(dir, "lde.json")) ---@cast raw -nil
	local config = json.decode(raw) ---@cast config table<string, any>
	test.truthy(config.devDependencies, "devDependencies should exist")
	test.truthy(config.devDependencies["mylib"], "mylib should be in devDependencies")
	test.equal(config.devDependencies["mylib"].path, "../mylib")
	test.falsy(config.dependencies and config.dependencies["mylib"], "mylib should not be in dependencies")
end)

test.it("lde add --dev creates devDependencies if not present in config", function()
	local dir = makeProject("dev-create-test")
	-- makeProject writes a config with no devDependencies key
	local raw = fs.read(path.join(dir, "lde.json")) ---@cast raw -nil
	local config = json.decode(raw) ---@cast config table<string, any>
	test.falsy(config.devDependencies, "devDependencies should not exist initially")

	ldecli({ "add", "mylib", "--dev", "--path", "../mylib" }, dir)

	local raw = fs.read(path.join(dir, "lde.json")) ---@cast raw -nil
	local updated = json.decode(raw) ---@cast updated table<string, any>
	test.truthy(updated.devDependencies, "devDependencies should be created")
	test.truthy(updated.devDependencies["mylib"], "mylib should be in devDependencies")
end)

test.skipIf(env.var("ANDROID_ROOT") ~= nil)("lde add --dev --git adds git dep to devDependencies", function()
	local dir = makeProject("dev-git-test")
	local repoDir = makeGitRepo("dev-git-repo")
	ldecli({ "add", "mypkg", "--dev", "--git", repoDir }, dir)

	local raw = fs.read(path.join(dir, "lde.json")) ---@cast raw -nil
	local config = json.decode(raw) ---@cast config table<string, any>
	test.truthy(config.devDependencies, "devDependencies should exist")
	test.truthy(config.devDependencies["mypkg"], "mypkg should be in devDependencies")
	test.equal(config.devDependencies["mypkg"].git, repoDir)
	test.falsy(config.dependencies and config.dependencies["mypkg"], "mypkg should not be in dependencies")
end)

test.skipIf(env.var("ANDROID_ROOT") ~= nil)("lde add --dev --git --branch stores branch in devDependencies", function()
	local dir = makeProject("dev-git-branch-test")
	local repoDir = makeGitRepo("dev-git-branch-repo")
	-- Rename the default branch so the --branch ref actually exists.
	assert(process.exec("git", { "branch", "-m", "main" }, { cwd = repoDir }), "git branch rename failed")
	ldecli({ "add", "mypkg", "--dev", "--git", repoDir, "--branch", "main" }, dir)

	local raw = fs.read(path.join(dir, "lde.json")) ---@cast raw -nil
	local config = json.decode(raw) ---@cast config table<string, any>
	test.truthy(config.devDependencies, "devDependencies should exist")
	local dep = config.devDependencies["mypkg"]
	test.truthy(dep, "mypkg should be in devDependencies")
	test.equal(dep.git, repoDir)
	test.equal(dep.branch, "main")
end)

test.it("lde add --dev does not affect existing dependencies", function()
	local dir = makeProject("dev-isolation-test")
	-- Pre-populate a regular dependency
	ldecli({ "add", "existing", "--path", "../existing" }, dir)

	ldecli({ "add", "devonly", "--dev", "--path", "../devonly" }, dir)

	local raw = fs.read(path.join(dir, "lde.json")) ---@cast raw -nil
	local config = json.decode(raw) ---@cast config table<string, any>
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

	local raw = fs.read(path.join(dir, "lde.lock")) ---@cast raw -nil
	local lock = json.decode(raw) ---@cast lock table<string, any>
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
	test.truthy(ok, "lde add --dev failed: " .. tostring(out)) ---@cast out -nil

	local raw = fs.read(path.join(dir, "lde.json")) ---@cast raw -nil
	local config = json.decode(raw) ---@cast config table<string, any>
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
	test.truthy(lockRaw, "lde.lock should still exist") ---@cast lockRaw -nil
	local lock = json.decode(lockRaw) ---@cast lock table<string, any>
	test.falsy(lock.dependencies["mypkg"], "stale lockfile entry should be removed after lde add")
	test.falsy(fs.exists(path.join(dir, "target", ".installed")), ".installed should be deleted")
end)

test.skipIf(env.var("ANDROID_ROOT") ~= nil)("lde add --git pins the commit in the lockfile at add time", function()
	-- Local repo so the whole flow is offline (lsRemote + clone on local paths).
	-- The package inside the repo must be named "addgit" — that's the require
	-- alias findNamedPackage matches against during sync.
	local repoDir = makeGitRepo("add-git-repo", "addgit")

	local dir = makeProject("add-git-test")
	local ok, out = ldecli({ "add", "addgit", "--git", repoDir }, dir)
	test.truthy(ok, "lde add --git failed: " .. tostring(out))

	local raw = fs.read(path.join(dir, "lde.json")) ---@cast raw -nil
	local config = json.decode(raw) ---@cast config table<string, any>
	test.truthy(config.dependencies["addgit"], "addgit should be in dependencies")
	test.equal(config.dependencies["addgit"].git, repoDir)

	-- The commit is auto-pinned by add itself (lsRemote at add time): the
	-- lockfile is created immediately and carries the resolved HEAD sha.
	local lockPath = path.join(dir, "lde.lock")
	test.truthy(fs.exists(lockPath), "lde add --git must create the lockfile")
	local lockRaw = fs.read(lockPath) ---@cast lockRaw -nil
	local lock = json.decode(lockRaw) ---@cast lock table<string, any>
	local entry = lock.dependencies["addgit"]
	test.truthy(entry and entry.commit, "add must pin the commit immediately")
	test.truthy(entry.commit:match("^%x+$"), "expected a hex commit sha")
	test.equal(entry.git, repoDir)

	-- sync reuses the add-time pin (no re-resolution) and installs the dep.
	local ok2, out2 = ldecli({ "sync" }, dir)
	test.truthy(ok2, "sync failed: " .. tostring(out2))
	local lockAfterRaw = fs.read(lockPath) ---@cast lockAfterRaw -nil
	local lockAfter = json.decode(lockAfterRaw) ---@cast lockAfter table<string, any>
	test.equal(lockAfter.dependencies["addgit"].commit, entry.commit, "sync must keep the add-time pin")
	test.truthy(fs.exists(path.join(dir, "target", "addgit", "init.lua")))
end)

test.skipIf(env.var("ANDROID_ROOT") ~= nil)("lde add --git fails on a nonexistent repository and leaves the manifest untouched", function()
	local dir = makeProject("add-git-missing-test")
	local ok, out = ldecli({ "add", "missing", "--git", path.join(tmpBase, "no-such-repo") }, dir)
	test.falsy(ok, "adding a nonexistent repo must fail")
	test.includes(out or "", "Failed to resolve")

	-- The failed add must not have written the manifest or a lockfile.
	local raw = fs.read(path.join(dir, "lde.json")) ---@cast raw -nil
	local config = json.decode(raw) ---@cast config table<string, any>
	test.falsy(config.dependencies["missing"], "manifest must be untouched after a failed add")
	test.falsy(fs.exists(path.join(dir, "lde.lock")), "no lockfile should be written on a failed add")
end)

test.skipIf(env.var("ANDROID_ROOT") ~= nil)("lde add --git --commit skips resolution and records the pin offline", function()
	local dir = makeProject("add-git-commit-test")
	-- A commit that need not exist: --commit is a deliberate pin, so add must
	-- not reach the network. The manifest carries it verbatim.
	local ok, out = ldecli({ "add", "pinned", "--git", "https://example.com/pinned.git", "--commit", "deadbeef" }, dir)
	test.truthy(ok, "lde add --git --commit failed: " .. tostring(out))

	local raw = fs.read(path.join(dir, "lde.json")) ---@cast raw -nil
	local config = json.decode(raw) ---@cast config table<string, any>
	local dep = config.dependencies["pinned"]
	test.truthy(dep, "pinned should be in dependencies")
	test.equal(dep.git, "https://example.com/pinned.git")
	test.equal(dep.commit, "deadbeef")

	local lockRaw = fs.read(path.join(dir, "lde.lock")) ---@cast lockRaw -nil
	local lock = json.decode(lockRaw) ---@cast lock table<string, any>
	test.equal(lock.dependencies["pinned"].commit, "deadbeef", "lockfile should carry the explicit commit")
end)

test.it("lde add <name>@latest pins the newest version", function()
	-- Fully offline fake registry (see the --dev registry test above).
	local repoDir = path.join(tmpBase, "add-latest-repo")
	fs.rmdir(repoDir)
	fs.mkdir(repoDir)
	fs.mkdir(path.join(repoDir, "src"))
	fs.write(path.join(repoDir, "src", "init.lua"), 'return "add-latest"')
	fs.write(path.join(repoDir, "lde.json"), json.encode({
		name = "add-latest",
		version = "0.1.0",
		dependencies = {}
	}))

	local treeDir = path.join(tmpBase, "add-latest-reg")
	fs.rmdir(treeDir)
	fs.mkdir(treeDir)
	fs.mkdirAll(path.join(treeDir, "registry", "packages"))
	fs.write(path.join(treeDir, "registry", "packages", "add-latest.json"), json.encode({
		name = "add-latest",
		description = "offline test package",
		git = repoDir,
		branch = "master",
		versions = { ["1.0.0"] = "1111111", ["2.0.0"] = "2222222" }
	}))

	local dir = makeProject("add-latest-test")
	local ok, out = ldecli({ "--tree", treeDir, "add", "add-latest@latest" }, dir)
	test.truthy(ok, "lde add add-latest@latest failed: " .. tostring(out)) ---@cast out -nil

	local raw = fs.read(path.join(dir, "lde.json")) ---@cast raw -nil
	local config = json.decode(raw) ---@cast config table<string, any>
	local dep = config.dependencies["add-latest"]
	test.truthy(dep, "add-latest should be in dependencies")
	-- @latest must resolve to the concrete newest version, not a "latest" marker.
	test.equal(dep.version, "2.0.0")
end)

--
-- Re-pinning existing dependencies (lde add name@version / --version)
--

test.it("lde add name@version re-pins an existing luarocks dep", function()
	local dir = makeProject("repin-rocks-test")
	local ok, out = ldecli({ "add", "rocks:semver" }, dir)
	test.truthy(ok, "first add failed: " .. tostring(out)) ---@cast out -nil

	-- No rocks: prefix needed: the existing entry's kind routes the update.
	ok, out = ldecli({ "add", "semver@1.1.0" }, dir)
	test.truthy(ok, "re-pin failed: " .. tostring(out))
	test.includes(out or "", "Updated")

	local raw = fs.read(path.join(dir, "lde.json")) ---@cast raw -nil
	local config = json.decode(raw) ---@cast config table<string, any>
	test.equal(config.dependencies.semver.version, "1.1.0")

	-- The --version flag form re-pins the same way.
	ok, out = ldecli({ "add", "semver", "--version", "1.2.0" }, dir)
	test.truthy(ok, "--version re-pin failed: " .. tostring(out))
	test.includes(out or "", "Updated")

	raw = fs.read(path.join(dir, "lde.json")) ---@cast raw -nil
	config = json.decode(raw) ---@cast config table<string, any>
	test.equal(config.dependencies.semver.version, "1.2.0")
end)

test.it("lde add with no version on an existing dep still warns", function()
	local dir = makeProject("repin-warn-test")
	local ok, out = ldecli({ "add", "rocks:semver" }, dir)
	test.truthy(ok, "first add failed: " .. tostring(out)) ---@cast out -nil

	ok, out = ldecli({ "add", "semver" }, dir)
	test.truthy(ok)
	test.includes(out or "", "already exists")

	-- The manifest is untouched: no version pin appears.
	local raw = fs.read(path.join(dir, "lde.json")) ---@cast raw -nil
	local config = json.decode(raw) ---@cast config table<string, any>
	test.falsy(config.dependencies.semver.version, "bare add must not pin a version")
end)

test.it("lde add an existing dep to a nonexistent version fails cleanly", function()
	local dir = makeProject("repin-badver-test")
	local ok, out = ldecli({ "add", "rocks:semver" }, dir)
	test.truthy(ok, "first add failed: " .. tostring(out)) ---@cast out -nil

	ok, out = ldecli({ "add", "semver@99.0.0" }, dir)
	test.falsy(ok, "nonexistent version must fail")
	test.includes(out or "", "No version of")
end)

test.skipIf(env.var("ANDROID_ROOT") ~= nil)("lde add version on a git/path dep fails cleanly", function()
	local dir = makeProject("repin-git-test")
	local repoDir = makeGitRepo("repin-git-repo")
	local ok, out = ldecli({ "add", "mypkg", "--git", repoDir }, dir)
	test.truthy(ok, "git add failed: " .. tostring(out))

	ok, out = ldecli({ "add", "mypkg@1.0.0" }, dir)
	test.falsy(ok, "version on a git dep must fail")
	test.includes(out or "", "git dependency")

	ok, out = ldecli({ "add", "mypkg", "--path", "../mylib" }, dir)
	test.truthy(ok, "switching to a path dep failed: " .. tostring(out))
	test.includes(out or "", "Updated")
	ok, out = ldecli({ "add", "mypkg@1.0.0" }, dir)
	test.falsy(ok, "version on a path dep must fail")
	test.includes(out or "", "path dependency")
end)

test.it("lde add name@version re-pins an existing registry dep", function()
	-- Fully offline fake registry (same shape as the @latest test above).
	local repoDir = path.join(tmpBase, "repin-reg-repo")
	fs.rmdir(repoDir)
	fs.mkdir(repoDir)
	fs.mkdir(path.join(repoDir, "src"))
	fs.write(path.join(repoDir, "src", "init.lua"), 'return "repin-reg"')
	fs.write(path.join(repoDir, "lde.json"), json.encode({
		name = "repin-reg",
		version = "0.1.0",
		dependencies = {}
	}))

	local treeDir = path.join(tmpBase, "repin-reg-tree")
	fs.rmdir(treeDir)
	fs.mkdir(treeDir)
	fs.mkdirAll(path.join(treeDir, "registry", "packages"))
	fs.write(path.join(treeDir, "registry", "packages", "repin-reg.json"), json.encode({
		name = "repin-reg",
		description = "offline test package",
		git = repoDir,
		branch = "master",
		versions = { ["1.0.0"] = "1111111", ["2.0.0"] = "2222222" }
	}))

	local dir = makeProject("repin-reg-test")
	local ok, out = ldecli({ "--tree", treeDir, "add", "repin-reg" }, dir)
	test.truthy(ok, "first add failed: " .. tostring(out)) ---@cast out -nil

	ok, out = ldecli({ "--tree", treeDir, "add", "repin-reg@1.0.0" }, dir)
	test.truthy(ok, "re-pin failed: " .. tostring(out))
	test.includes(out or "", "Updated")

	local raw = fs.read(path.join(dir, "lde.json")) ---@cast raw -nil
	local config = json.decode(raw) ---@cast config table<string, any>
	test.equal(config.dependencies["repin-reg"].version, "1.0.0")
end)
