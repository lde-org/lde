-- End-to-end tests for `lde sync`: installs, cache invalidation (manual
-- deletion of target/, .installed, the lockfile, and the git/tar caches),
-- build.lua input-change invalidation, and the --locked / --production flags.
--
-- All cache-deletion scenarios are scoped with --tree so they never touch the
-- shared ~/.lde cache other tests rely on.
local test = require("lde-test")

local lde = require("lde-core")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")
local process = require("process")

local cli = require("tests.lib.ldecli")

local tmpBase = path.join(env.tmpdir(), "lde-sync-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

---Strip ANSI escape sequences so output matches work with or without colors.
---@param s string
---@return string
local function plain(s)
	return ((s or ""):gsub("\27%[[0-9;]*m", ""))
end

---@param name string
---@param deps table?
---@param extra table?
---@return string dir
local function makeProject(name, deps, extra)
	local dir = path.join(tmpBase, name)
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), 'return "' .. name .. '"')
	local config = {
		name = name,
		version = "0.1.0",
		dependencies = deps or {}
	}
	if extra then
		for k, v in pairs(extra) do config[k] = v end
	end
	fs.write(path.join(dir, "lde.json"), json.encode(config))
	return dir
end

---@param name string
---@return string dir
local function makeDep(name)
	return makeProject(name)
end

--- A local git repo usable as an offline `git:` dependency (libgit2's
--- lsRemote/clone both accept plain local paths). Returns the repo dir.
---@param name string
---@param packageName string? # lde.json name (defaults to the dir name)
---@return string repoDir
local function makeLocalGitRepo(name, packageName)
	local repoDir = path.join(tmpBase, name .. "-repo")
	fs.rmdir(repoDir)
	fs.mkdir(repoDir)
	fs.mkdir(path.join(repoDir, "src"))
	fs.write(path.join(repoDir, "src", "init.lua"), 'return "' .. name .. '"')
	fs.write(path.join(repoDir, "lde.json"), json.encode({
		name = packageName or name,
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

--
-- Basic installs
--

test.it("lde sync installs path dependencies and writes the lockfile", function()
	makeDep("sync-basic-dep")
	local dir = makeProject("sync-basic", { ["sync-basic-dep"] = { path = "../sync-basic-dep" } })

	local ok, out = cli({ "sync" }, dir)
	test.truthy(ok, "lde sync failed: " .. tostring(out))

	test.truthy(fs.exists(path.join(dir, "target", "sync-basic-dep", "init.lua")))
	test.truthy(fs.exists(path.join(dir, "lde.lock")))
	test.truthy(fs.exists(path.join(dir, "target", ".installed")))
	local lockRaw = fs.read(path.join(dir, "lde.lock")) ---@cast lockRaw -nil
	local lock = json.decode(lockRaw) ---@cast lock table<string, any>
	test.equal(lock.dependencies["sync-basic-dep"].path, "../sync-basic-dep")
end)

test.it("lde sync is a cached no-op when nothing changed", function()
	makeDep("sync-cached-dep")
	local dir = makeProject("sync-cached", { ["sync-cached-dep"] = { path = "../sync-cached-dep" } })

	local ok, out = cli({ "sync" }, dir)
	test.truthy(ok, "first sync failed: " .. tostring(out))

	local ok2, out2 = cli({ "sync" }, dir)
	test.truthy(ok2, "second sync failed: " .. tostring(out2))
	local text = plain(out2 or "")
	test.includes(text, "No changes")
	test.includes(text, "(cached)")
end)

--
-- Manual cache deletion invalidates the sync
--

test.it("lde sync re-installs when target/.installed is deleted", function()
	makeDep("sync-installed-dep")
	local dir = makeProject("sync-installed", { ["sync-installed-dep"] = { path = "../sync-installed-dep" } })

	cli({ "sync" }, dir)
	fs.delete(path.join(dir, "target", ".installed"))

	local ok, out = cli({ "sync" }, dir)
	test.truthy(ok, "sync after .installed deletion failed: " .. tostring(out))
	test.falsy(plain(out or ""):find("(cached)", 1, true),
		"sync must not report cached after .installed was deleted")
	test.truthy(fs.exists(path.join(dir, "target", "sync-installed-dep", "init.lua")))
end)

test.it("lde sync re-installs when a dependency is deleted from target/", function()
	makeDep("sync-wipe-dep")
	local dir = makeProject("sync-wipe", { ["sync-wipe-dep"] = { path = "../sync-wipe-dep" } })

	cli({ "sync" }, dir)
	fs.rmdir(path.join(dir, "target", "sync-wipe-dep"))

	local ok, out = cli({ "sync" }, dir)
	test.truthy(ok, "sync after dep wipe failed: " .. tostring(out))
	test.falsy(plain(out or ""):find("(cached)", 1, true))
	test.truthy(fs.exists(path.join(dir, "target", "sync-wipe-dep", "init.lua")))
end)

test.it("lde sync re-installs everything when target/ is deleted", function()
	makeDep("sync-nuke-dep")
	local dir = makeProject("sync-nuke", { ["sync-nuke-dep"] = { path = "../sync-nuke-dep" } })

	cli({ "sync" }, dir)
	fs.rmdir(path.join(dir, "target"))

	local ok, out = cli({ "sync" }, dir)
	test.truthy(ok, "sync after target wipe failed: " .. tostring(out))
	test.falsy(plain(out or ""):find("(cached)", 1, true))
	test.truthy(fs.exists(path.join(dir, "target", "sync-nuke-dep", "init.lua")))
end)

test.it("lde sync re-creates the lockfile when it is deleted", function()
	makeDep("sync-lock-del-dep")
	local dir = makeProject("sync-lock-del", { ["sync-lock-del-dep"] = { path = "../sync-lock-del-dep" } })

	cli({ "sync" }, dir)
	fs.delete(path.join(dir, "lde.lock"))
	fs.delete(path.join(dir, "target", ".installed"))

	local ok, out = cli({ "sync" }, dir)
	test.truthy(ok, "sync after lockfile deletion failed: " .. tostring(out))
	test.truthy(fs.exists(path.join(dir, "lde.lock")))
	test.truthy(fs.exists(path.join(dir, "target", "sync-lock-del-dep", "init.lua")))
end)

test.it("lde sync installs a newly added dependency after lde.json changes", function()
	makeDep("sync-new-a")
	makeDep("sync-new-b")
	local dir = makeProject("sync-new", { ["sync-new-a"] = { path = "../sync-new-a" } })

	cli({ "sync" }, dir)
	test.falsy(fs.exists(path.join(dir, "target", "sync-new-b")))

	-- The .installed marker hashes the manifest, so editing lde.json (even
	-- without touching the lockfile) must invalidate the cache.
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "sync-new",
		version = "0.1.0",
		dependencies = {
			["sync-new-a"] = { path = "../sync-new-a" },
			["sync-new-b"] = { path = "../sync-new-b" }
		}
	}))

	local ok, out = cli({ "sync" }, dir)
	test.truthy(ok, "sync after manifest change failed: " .. tostring(out))
	test.truthy(fs.exists(path.join(dir, "target", "sync-new-b", "init.lua")))
	test.truthy(fs.exists(path.join(dir, "target", "sync-new-a", "init.lua")))
end)

--
-- Cache directory (tar / git) invalidation — scoped with --tree
--

test.it("lde sync re-downloads when the tar cache is deleted", function()
	local treeDir = path.join(tmpBase, "sync-tar-tree")
	fs.rmdir(treeDir)
	local dir = makeProject("sync-tar", { lpeg = { luarocks = "lpeg" } })

	local ok, out = cli({ "--tree", treeDir, "sync" }, dir)
	test.truthy(ok, "initial sync failed: " .. tostring(out))
	test.truthy(fs.exists(path.join(dir, "target", "lpeg")), "lpeg not installed")

	-- Wipe the tar cache AND the materialized dep: the .installed hash alone
	-- can't see either, so a full re-download must happen.
	fs.rmdir(path.join(treeDir, "tar"))
	fs.rmdir(path.join(dir, "target", "lpeg"))

	local ok2, out2 = cli({ "--tree", treeDir, "sync" }, dir)
	test.truthy(ok2, "sync after tar cache wipe failed: " .. tostring(out2))
	test.includes(plain(out2 or ""), "All dependencies installed successfully")
	test.truthy(fs.exists(path.join(dir, "target", "lpeg")), "lpeg not re-installed")
end)

test.skipIf(env.var("ANDROID_ROOT") ~= nil)("lde sync re-clones when the git cache is deleted", function()
	local repoDir = makeLocalGitRepo("syncgit")
	local treeDir = path.join(tmpBase, "sync-git-tree")
	fs.rmdir(treeDir)
	local dir = makeProject("sync-git-app", { syncgit = { git = repoDir } })

	local ok, out = cli({ "--tree", treeDir, "sync" }, dir)
	test.truthy(ok, "initial sync failed: " .. tostring(out))
	test.truthy(fs.exists(path.join(dir, "target", "syncgit", "init.lua")))

	-- Deleting the git cache dangles the target/syncgit symlink. installIsIntact
	-- must detect it (fs.exists follows the link) and re-clone.
	fs.rmdir(path.join(treeDir, "git"))
	test.falsy(fs.exists(path.join(dir, "target", "syncgit", "init.lua")),
		"precondition: symlink should dangle after cache wipe")

	local ok2, out2 = cli({ "--tree", treeDir, "sync" }, dir)
	test.truthy(ok2, "sync after git cache wipe failed: " .. tostring(out2))
	test.falsy(plain(out2 or ""):find("(cached)", 1, true))
	test.truthy(fs.exists(path.join(dir, "target", "syncgit", "init.lua")))
end)

--
-- --locked and --production
--

test.skipIf(env.var("ANDROID_ROOT") ~= nil)("lde sync --locked works when the lockfile is up to date", function()
	local repoDir = makeLocalGitRepo("synclocked")
	local treeDir = path.join(tmpBase, "sync-locked-tree")
	fs.rmdir(treeDir)
	local dir = makeProject("sync-locked-ok-app", { synclocked = { git = repoDir } })

	local ok, out = cli({ "--tree", treeDir, "sync" }, dir)
	test.truthy(ok, "initial sync failed: " .. tostring(out))

	local ok2, out2 = cli({ "--tree", treeDir, "sync", "--locked" }, dir)
	test.truthy(ok2, "sync --locked failed: " .. tostring(out2))
	test.truthy(fs.exists(path.join(dir, "target", "synclocked", "init.lua")))
end)

test.skipIf(env.var("ANDROID_ROOT") ~= nil)("lde sync --locked fails when the lockfile is out of date", function()
	local repoDir = makeLocalGitRepo("synclockedbad")
	local treeDir = path.join(tmpBase, "sync-locked-bad-tree")
	fs.rmdir(treeDir)
	local dir = makeProject("sync-locked-bad-app", { synclockedbad = { git = repoDir } })

	-- No lockfile exists yet: the git dep is unpinned, so --locked must fail
	-- loudly instead of resolving a fresh commit.
	local ok, out = cli({ "--tree", treeDir, "sync", "--locked" }, dir)
	test.falsy(ok, "sync --locked should fail on an unpinned dep")
	test.includes(plain(out or ""), "not pinned")
end)

test.it("lde sync --production skips dev dependencies", function()
	makeDep("sync-prod-runtime")
	makeDep("sync-prod-dev")
	local dir = makeProject("sync-prod", {
		["sync-prod-runtime"] = { path = "../sync-prod-runtime" }
	}, {
		devDependencies = {
			["sync-prod-dev"] = { path = "../sync-prod-dev" }
		}
	})

	local ok, out = cli({ "sync", "--production" }, dir)
	test.truthy(ok, "sync --production failed: " .. tostring(out))

	test.truthy(fs.exists(path.join(dir, "target", "sync-prod-runtime", "init.lua")))
	test.falsy(fs.exists(path.join(dir, "target", "sync-prod-dev")),
		"dev dep must not be installed with --production")
	-- The dev dep must not be pinned into the lockfile either.
	local lockRaw = fs.read(path.join(dir, "lde.lock")) ---@cast lockRaw -nil
	local lock = json.decode(lockRaw) ---@cast lock table<string, any>
	test.falsy(lock.dependencies["sync-prod-dev"])
end)

--
-- Registry dependencies — resolved fully offline through a fake local registry
--

--- Writes a one-package registry into the --tree dir. The portfile's git URL
--- points at a local repo, so the whole flow (registry lookup, clone, lockfile
--- pinning) never touches the network. When `ns` is given, the package is
--- stored namespaced at packages/<ns>/<pkgName>.json.
---@param treeDir string
---@param repoDir string
---@param commit string
---@param ns string?
---@param pkgName string? # portfile/package name (defaults to sync-reg-pkg)
local function writeFakeRegistry(treeDir, repoDir, commit, ns, pkgName)
	pkgName = pkgName or "sync-reg-pkg"
	local registryDir = path.join(treeDir, "registry")
	local fullName = ns and (ns .. "/" .. pkgName) or pkgName
	local pkgPath = ns
		and path.join(registryDir, "packages", ns, pkgName .. ".json")
		or path.join(registryDir, "packages", pkgName .. ".json")
	fs.mkdirAll(path.dirname(pkgPath))
	fs.write(pkgPath, json.encode({
		name = fullName,
		description = "offline test package",
		git = repoDir,
		branch = "master",
		versions = { ["1.0.0"] = commit }
	}))
end

---@param repoDir string
---@return string commit
local function headCommit(repoDir)
	local code, out = process.exec("git", { "rev-parse", "HEAD" }, { cwd = repoDir })
	test.equal(code, 0, tostring(out))
	return ((out or ""):gsub("%s+$", ""))
end

test.skipIf(env.var("ANDROID_ROOT") ~= nil)("lde sync pins the resolved git repo for a registry dep and reinstalls from it", function()
	-- The repo's lde.json must carry the registry package name, or
	-- findNamedPackage can't locate it after the clone.
	local repoDir = makeLocalGitRepo("sync-reg-src", "sync-reg-pkg")
	local commit = headCommit(repoDir)

	local treeDir = path.join(tmpBase, "sync-reg-tree")
	fs.rmdir(treeDir)
	fs.mkdir(treeDir)
	writeFakeRegistry(treeDir, repoDir, commit)

	local dir = makeProject("sync-reg-app", { ["sync-reg-pkg"] = { version = "1.0.0" } })

	local ok, out = cli({ "--tree", treeDir, "sync" }, dir)
	test.truthy(ok, "sync failed: " .. tostring(out))
	test.truthy(fs.exists(path.join(dir, "target", "sync-reg-pkg", "init.lua")))

	-- Regression: the lock entry must pin the git repo, not just the commit.
	-- A commit-only entry can't be classified on the next install and errors
	-- with "Unsupported dependency type for: <alias>".
	local lockRaw = fs.read(path.join(dir, "lde.lock")) ---@cast lockRaw -nil
	local lock = json.decode(lockRaw) ---@cast lock table<string, any>
	local entry = lock.dependencies["sync-reg-pkg"]
	test.equal(entry.git, repoDir)
	test.equal(entry.commit, commit)

	-- Wipe target/: the pinned lock entry alone must be enough to reinstall
	-- (no registry lookup, no network).
	fs.rmdir(path.join(dir, "target"))
	local ok2, out2 = cli({ "--tree", treeDir, "sync" }, dir)
	test.truthy(ok2, "sync after target wipe failed: " .. tostring(out2))
	test.truthy(fs.exists(path.join(dir, "target", "sync-reg-pkg", "init.lua")))
end)

test.skipIf(env.var("ANDROID_ROOT") ~= nil)("lde sync heals a stale commit-only lock entry for a registry dep", function()
	local repoDir = makeLocalGitRepo("sync-reg-heal-src", "sync-reg-pkg")
	local commit = headCommit(repoDir)

	local treeDir = path.join(tmpBase, "sync-reg-heal-tree")
	fs.rmdir(treeDir)
	fs.mkdir(treeDir)
	writeFakeRegistry(treeDir, repoDir, commit)

	local dir = makeProject("sync-reg-heal-app", { ["sync-reg-pkg"] = { version = "1.0.0" } })

	-- Simulate a lockfile written before registry deps recorded their git URL:
	-- the entry carries a commit but no git field. Sync must re-resolve from
	-- the manifest's version and rewrite the entry instead of erroring. The
	-- manifest hash matches lde.json so the pins are still considered valid.
	local manifestRaw = fs.read(path.join(dir, "lde.json")) ---@cast manifestRaw -nil
	local manifest = json.decode(manifestRaw) --[[@as lde.Package.Config]]
	fs.write(path.join(dir, "lde.lock"), json.encode({
		version = "1",
		manifestHash = lde.Lockfile.manifestHash(manifest),
		dependencies = {
			["sync-reg-pkg"] = { commit = commit }
		}
	}))

	local ok, out = cli({ "--tree", treeDir, "sync" }, dir)
	test.truthy(ok, "sync with stale lock entry failed: " .. tostring(out))

	local lockRaw = fs.read(path.join(dir, "lde.lock")) ---@cast lockRaw -nil
	local lock = json.decode(lockRaw) ---@cast lock table<string, any>
	local entry = lock.dependencies["sync-reg-pkg"]
	test.equal(entry.git, repoDir, "stale lock entry should be healed with the git repo")
	test.truthy(fs.exists(path.join(dir, "target", "sync-reg-pkg", "init.lua")))
end)

test.skipIf(env.var("ANDROID_ROOT") ~= nil)("lde sync installs a namespaced registry dependency", function()
	-- The repo's lde.json must carry the full namespaced name, or
	-- findNamedPackage can't locate it after the clone.
	local repoDir = makeLocalGitRepo("sync-reg-ns-src", "ns-owner/sync-reg-pkg")
	local commit = headCommit(repoDir)

	local treeDir = path.join(tmpBase, "sync-reg-ns-tree")
	fs.rmdir(treeDir)
	fs.mkdir(treeDir)
	writeFakeRegistry(treeDir, repoDir, commit, "ns-owner")

	local dir = makeProject("sync-reg-ns-app", { ["ns-owner/sync-reg-pkg"] = { version = "1.0.0" } })

	local ok, out = cli({ "--tree", treeDir, "sync" }, dir)
	test.truthy(ok, "sync failed: " .. tostring(out))

	-- The namespaced alias materializes as a nested target dir and require
	-- name (target/ns-owner/sync-reg-pkg, i.e. ns-owner.sync-reg-pkg).
	test.truthy(fs.exists(path.join(dir, "target", "ns-owner", "sync-reg-pkg", "init.lua")))

	local lockRaw = fs.read(path.join(dir, "lde.lock")) ---@cast lockRaw -nil
	local lock = json.decode(lockRaw) ---@cast lock table<string, any>
	local entry = lock.dependencies["ns-owner/sync-reg-pkg"]
	test.equal(entry.git, repoDir)
	test.equal(entry.commit, commit)

	-- Wipe target/: the pinned lock entry alone must be enough to reinstall
	-- (no registry lookup, no network).
	fs.rmdir(path.join(dir, "target"))
	local ok2, out2 = cli({ "--tree", treeDir, "sync" }, dir)
	test.truthy(ok2, "sync after target wipe failed: " .. tostring(out2))
	test.truthy(fs.exists(path.join(dir, "target", "ns-owner", "sync-reg-pkg", "init.lua")))
end)

test.skipIf(env.var("ANDROID_ROOT") ~= nil)("lde sync re-resolves a dep switched from git to registry in lde.json", function()
	-- Phase 1: a git dependency, pinned in the lockfile.
	local gitRepo = makeLocalGitRepo("sync-switch-git", "sync-switch-pkg")
	local gitCommit = headCommit(gitRepo)

	-- The registry serves the same package name from a *different* repo, so a
	-- stale lockfile pin would be observably wrong (wrong git URL and commit).
	local regRepo = makeLocalGitRepo("sync-switch-reg", "sync-switch-pkg")
	local regCommit = headCommit(regRepo)

	-- A parent package that requests the package as a *registry* dep: the same
	-- alias then reaches the graph in registry form, which used to trip the
	-- "Conflicting sources" error against the stale git pin.
	local parentRepo = makeLocalGitRepo("sync-switch-parent", "sync-switch-parent")
	fs.write(path.join(parentRepo, "lde.json"), json.encode({
		name = "sync-switch-parent",
		version = "0.1.0",
		dependencies = { ["sync-switch-pkg"] = { version = "1.0.0" } }
	}))
	assert(process.exec("git", { "add", "-A" }, { cwd = parentRepo }), "git add failed")
	local code = process.exec(
		"git", { "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "registry dep" },
		{ cwd = parentRepo })
	assert(code == 0, "git commit failed: " .. tostring(code))
	local parentCommit = headCommit(parentRepo)

	local treeDir = path.join(tmpBase, "sync-switch-tree")
	fs.rmdir(treeDir)
	fs.mkdir(treeDir)
	writeFakeRegistry(treeDir, regRepo, regCommit, nil, "sync-switch-pkg")
	writeFakeRegistry(treeDir, parentRepo, parentCommit, nil, "sync-switch-parent")

	-- Phase 1: git dep.
	local dir = makeProject("sync-switch-app", {
		["sync-switch-pkg"] = { git = gitRepo }
	})
	local ok, out = cli({ "--tree", treeDir, "sync" }, dir)
	test.truthy(ok, "initial sync failed: " .. tostring(out))
	local lock1Raw = fs.read(path.join(dir, "lde.lock")) ---@cast lock1Raw -nil
	local lock1 = json.decode(lock1Raw) ---@cast lock1 table<string, any>
	test.equal(lock1.dependencies["sync-switch-pkg"].git, gitRepo)
	test.equal(lock1.dependencies["sync-switch-pkg"].commit, gitCommit)

	-- Phase 2: the manifest switches the dep to the registry and adds the
	-- parent, which pulls the same alias from the registry too.
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "sync-switch-app",
		version = "0.1.0",
		dependencies = {
			["sync-switch-pkg"] = { version = "1.0.0" },
			["sync-switch-parent"] = { version = "1.0.0" }
		}
	}))

	local ok2, out2 = cli({ "--tree", treeDir, "sync" }, dir)
	test.truthy(ok2, "sync after git->registry switch failed: " .. tostring(out2))

	-- The stale git pin must not survive (and must not conflict with the
	-- parent's registry-form request): the alias re-resolves from the registry
	-- and the lockfile records the registry's repo.
	local lock2Raw = fs.read(path.join(dir, "lde.lock")) ---@cast lock2Raw -nil
	local lock2 = json.decode(lock2Raw) ---@cast lock2 table<string, any>
	test.equal(lock2.dependencies["sync-switch-pkg"].git, regRepo,
		"switched dep must re-resolve from the registry, not the stale git pin")
	test.equal(lock2.dependencies["sync-switch-pkg"].commit, regCommit)
	test.truthy(lock2.manifestHash, "lockfile must record the manifest hash")
end)

--
-- build.lua input invalidation through the CLI
--

--- A package whose build.lua appends to a marker file in the package dir, so
--- tests can count how many times it actually ran.
---@param name string
---@param marker string
---@return string dir
local function makeBuildProject(name, marker)
	local dir = makeProject(name)
	fs.write(path.join(dir, "build.lua"), string.format([[
local f = assert(io.open("%s", "a"))
f:write("x")
f:close()
]], marker))
	return dir
end

test.it("lde sync runs build.lua once and skips it while inputs are unchanged", function()
	local dir = makeBuildProject("sync-build-skip", "build-count-skip.txt")

	local ok, out = cli({ "sync" }, dir)
	test.truthy(ok, "first sync failed: " .. tostring(out))
	test.equal(fs.read(path.join(dir, "build-count-skip.txt")), "x")

	-- Nothing changed: the stamp-based skip must prevent a second run.
	local ok2, out2 = cli({ "sync" }, dir)
	test.truthy(ok2, "second sync failed: " .. tostring(out2))
	test.equal(fs.read(path.join(dir, "build-count-skip.txt")), "x",
		"build.lua must not re-run when src/, lde.json, and build.lua are unchanged")

	test.truthy(fs.exists(path.join(dir, "target", "sync-build-skip", ".lde-build-stamp")))
end)

test.it("lde sync re-runs build.lua when a src file changes", function()
	local dir = makeBuildProject("sync-build-src", "build-count-src.txt")

	cli({ "sync" }, dir)
	test.equal(fs.read(path.join(dir, "build-count-src.txt")), "x")

	-- Different size so the mtime/size fast path can't mask the change.
	fs.write(path.join(dir, "src", "init.lua"), 'return "changed-source-longer"')

	local ok, out = cli({ "sync" }, dir)
	test.truthy(ok, "sync after src change failed: " .. tostring(out))
	test.equal(fs.read(path.join(dir, "build-count-src.txt")), "xx",
		"build.lua must re-run after a src file changed")
end)

test.it("lde sync re-runs build.lua when build.lua itself changes", function()
	local dir = makeBuildProject("sync-build-script", "build-count-script.txt")

	cli({ "sync" }, dir)
	test.equal(fs.read(path.join(dir, "build-count-script.txt")), "x")

	-- Longer script so the size changes too.
	fs.write(path.join(dir, "build.lua"), string.format([[
local f = assert(io.open("%s", "a"))
f:write("x")
f:close()
-- extra line to change the file size
]], "build-count-script.txt"))

	local ok, out = cli({ "sync" }, dir)
	test.truthy(ok, "sync after build.lua change failed: " .. tostring(out))
	test.equal(fs.read(path.join(dir, "build-count-script.txt")), "xx",
		"build.lua must re-run when build.lua itself changed")
end)

test.it("lde sync re-runs a dependency's build.lua when the dependency source changes", function()
	local depDir = makeBuildProject("sync-build-dep", "dep-build-count.txt")
	local dir = makeProject("sync-build-dep-app", {
		["sync-build-dep"] = { path = "../sync-build-dep" }
	})

	cli({ "sync" }, dir)
	test.equal(fs.read(path.join(depDir, "dep-build-count.txt")), "x")

	-- Unchanged dep: no re-run on the next sync.
	cli({ "sync" }, dir)
	test.equal(fs.read(path.join(depDir, "dep-build-count.txt")), "x",
		"dep build.lua must not re-run while its inputs are unchanged")

	fs.write(path.join(depDir, "src", "init.lua"), 'return "dep-changed-longer"')

	local ok, out = cli({ "sync" }, dir)
	test.truthy(ok, "sync after dep src change failed: " .. tostring(out))
	test.equal(fs.read(path.join(depDir, "dep-build-count.txt")), "xx",
		"dep build.lua must re-run when the dependency's source changed")
end)

test.it("lde sync builds the package itself (target/<name> is materialized)", function()
	local dir = makeBuildProject("sync-build-self", "build-count-self.txt")

	local ok, out = cli({ "sync" }, dir)
	test.truthy(ok, "sync failed: " .. tostring(out))

	-- The package's own build ran (pkg:build is part of sync) and stamped the
	-- output dir — the same stamp that makes later syncs skip it.
	local outputDir = path.join(dir, "target", "sync-build-self")
	test.truthy(fs.exists(path.join(outputDir, ".lde-build-stamp")))
end)
