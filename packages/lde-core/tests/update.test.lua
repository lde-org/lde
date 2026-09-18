-- API-level tests for dependency updates (lde-core.package.update). The CLI
-- `lde update` flow is covered in packages/lde/tests/commands.test.lua; these
-- exercise updateDependencies directly, including the git re-pin path (offline
-- via a local repo) and the path-dep skip.
local test = require("lde-test")

local lde = require("lde-core")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")
local process = require("process")

local tmpBase = path.join(env.tmpdir(), "lde-update-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

---@param name string
---@param deps table?
---@return string dir
local function makeApp(name, deps)
	local dir = path.join(tmpBase, name)
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), 'return true')
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = name,
		version = "0.1.0",
		dependencies = deps or {}
	}))
	return dir
end

---@param name string
---@return string repoDir
local function makeLocalGitRepo(name)
	local repoDir = path.join(tmpBase, name .. "-repo")
	fs.rmdir(repoDir)
	fs.mkdir(repoDir)
	fs.mkdir(path.join(repoDir, "src"))
	fs.write(path.join(repoDir, "src", "init.lua"), 'return "' .. name .. '"')
	fs.write(path.join(repoDir, "lde.json"), json.encode({
		name = name,
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

--- The commit a repo's HEAD points at, trailing newline trimmed.
---@param repoDir string
---@return string
local function gitHead(repoDir)
	local _, stdout = process.exec("git", { "rev-parse", "HEAD" }, { cwd = repoDir })
	return ((stdout or ""):gsub("%s+$", ""))
end

--- Append a file + commit to a local repo (moving its HEAD forward).
---@param repoDir string
---@param file string
---@param content string
local function commitMore(repoDir, file, content)
	fs.write(path.join(repoDir, file), content)
	process.exec("git", { "add", "-A" }, { cwd = repoDir })
	local code = process.exec(
		"git", { "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "more" },
		{ cwd = repoDir })
	assert(code == 0, "second commit failed: " .. tostring(code))
end

test.it("updateDependencies skips path dependencies", function()
	local dir = makeApp("update-skip", {
		mylib = { path = "../mylib" }
	})
	local pkg = assert(lde.Package.open(dir))
	local results = pkg:updateDependencies()

	test.equal(results.mylib.updated, false)
	test.includes(results.mylib.message, "skipped")
end)

test.skipIf(env.var("ANDROID_ROOT") ~= nil)("updateDependencies reports already up to date for a git dep at HEAD", function()
	local repoDir = makeLocalGitRepo("update-head")
	local dir = makeApp("update-head-app", {
		["update-head"] = { git = repoDir }
	})
	local pkg = assert(lde.Package.open(dir))
	pkg:installDependencies()

	local results = pkg:updateDependencies()
	test.equal(results["update-head"].updated, false)
	test.includes(results["update-head"].message, "already up to date")
end)

test.skipIf(env.var("ANDROID_ROOT") ~= nil)("updateDependencies re-pins a git dep when the upstream moves", function()
	local repoDir = makeLocalGitRepo("update-move")
	local dir = makeApp("update-move-app", {
		["update-move"] = { git = repoDir }
	})
	local pkg = assert(lde.Package.open(dir))
	pkg:installDependencies()
	local before = pkg:readLockfile():getDependency("update-move").commit

	-- The repo moves forward; updateDependencies must pin the new commit in the
	-- lockfile (and only the lockfile — getDependencies reports from it).
	fs.write(path.join(repoDir, "src", "extra.lua"), 'return "v2"')
	process.exec("git", { "add", "-A" }, { cwd = repoDir })
	local code = process.exec(
		"git", { "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "more" },
		{ cwd = repoDir })
	assert(code == 0, "second commit failed")

	local results = pkg:updateDependencies()
	test.equal(results["update-move"].updated, true)
	test.includes(results["update-move"].message, "->")

	local after = pkg:readLockfile():getDependency("update-move").commit
	test.truthy(after ~= before, "lockfile commit must move to the new HEAD")

	-- A fresh install from the updated lockfile materializes the new content.
	pkg:installDependencies()
	test.truthy(fs.exists(path.join(dir, "target", "update-move", "extra.lua")),
		"updated commit must be installed")
end)

test.skipIf(env.var("ANDROID_ROOT") ~= nil)("updateDependencies leaves a git dep pinned by commit in lde.json alone", function()
	local repoDir = makeLocalGitRepo("update-pinned")
	local pinned = gitHead(repoDir)
	local dir = makeApp("update-pinned-app", {
		["update-pinned"] = { git = repoDir, commit = pinned }
	})
	local pkg = assert(lde.Package.open(dir))
	pkg:installDependencies()

	-- The upstream moves: an explicit commit in lde.json is a pin, so update
	-- must not move the lockfile past it.
	commitMore(repoDir, "src/v2.lua", 'return "v2"')

	local results = pkg:updateDependencies()
	test.equal(results["update-pinned"].updated, false)
	test.includes(results["update-pinned"].message, "pinned")
	test.equal(pkg:readLockfile():getDependency("update-pinned").commit, pinned,
		"a lde.json commit pin must survive update")

	-- And the next install still materializes the pinned commit.
	pkg:installDependencies()
	test.falsy(fs.exists(path.join(dir, "target", "update-pinned", "v2.lua")),
		"a pinned commit must not be replaced by the new HEAD")
	test.equal(pkg:readLockfile():getDependency("update-pinned").commit, pinned)
end)

test.skipIf(env.var("ANDROID_ROOT") ~= nil)("install re-pins a git dep whose lockfile records a different commit", function()
	local repoDir = makeLocalGitRepo("update-heal")
	local pinned = gitHead(repoDir)
	local dir = makeApp("update-heal-app", {
		["update-heal"] = { git = repoDir, commit = pinned }
	})
	local pkg = assert(lde.Package.open(dir))
	pkg:installDependencies()

	-- A lockfile left behind by an older lde (or an older lde update): it pins
	-- a newer commit than lde.json declares.
	commitMore(repoDir, "src/v2.lua", 'return "v2"')
	local moved = gitHead(repoDir)
	local lockfile = assert(pkg:readLockfile())
	lockfile:getDependency("update-heal").commit = moved
	lockfile:save()

	-- The manifest is the source of truth: install must go back to the pinned
	-- commit and re-pin the lockfile, never materialize the stray one.
	pkg:installDependencies()
	test.equal(pkg:readLockfile():getDependency("update-heal").commit, pinned,
		"the lockfile must be re-pinned to the lde.json commit")
	test.falsy(fs.exists(path.join(dir, "target", "update-heal", "v2.lua")),
		"the stray commit must not be installed")
end)
