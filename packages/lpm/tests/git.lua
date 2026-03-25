-- NOTE: These tests require network access — they clone from GitHub.
local test = require("lpm-test")

local lpm = require("lpm-core")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")

local tmpBase = path.join(env.tmpdir(), "lpm-git-tests")

-- Clean up from any previous test run
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

local GIT_URL = "https://github.com/codebycruz/lpm"
local FIXTURE_NAME = "lpm-test-fixture"

--- Creates a minimal package that depends on lpm-test-fixture via git.
local function makeProjectWithGitDep(name, extraDepFields)
	local dir = path.join(tmpBase, name)
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), "return true")

	local dep = { git = GIT_URL, branch = "master" }
	for k, v in pairs(extraDepFields or {}) do
		dep[k] = v
	end

	fs.write(path.join(dir, "lpm.json"), json.encode({
		name = name,
		version = "0.1.0",
		dependencies = { [FIXTURE_NAME] = dep }
	}))

	return dir
end

--
-- Git dependency installation
--

test.it("installDependencies installs a git dependency", function()
	local dir = makeProjectWithGitDep("git-basic")
	local pkg = lpm.Package.open(dir)
	pkg:installDependencies()

	local fixturePath = path.join(dir, "target", FIXTURE_NAME, "init.lua")
	test.truthy(fs.exists(fixturePath))
	test.equal(fs.read(fixturePath), 'return "lpm-test-fixture"\n')
end)

test.it("installDependencies writes a resolved commit to the lockfile for git deps", function()
	local dir = makeProjectWithGitDep("git-lockfile")
	local pkg = lpm.Package.open(dir)
	pkg:installDependencies()

	local lockRaw = fs.read(path.join(dir, "lpm-lock.json"))
	test.truthy(lockRaw)

	local lock = json.decode(lockRaw)
	local entry = lock.dependencies[FIXTURE_NAME]
	test.truthy(entry)
	test.truthy(entry.commit)
	-- Commit should be a 40-character hex SHA
	test.truthy(entry.commit:match("^%x+$"))
	test.equal(#entry.commit, 40)
end)

test.it("installDependencies uses the lockfile commit to skip re-cloning", function()
	local dir = makeProjectWithGitDep("git-reuse")
	local pkg = lpm.Package.open(dir)

	-- First install — clones and writes lockfile
	pkg:installDependencies()

	local lock1 = json.decode(fs.read(path.join(dir, "lpm-lock.json")))
	local commit1 = lock1.dependencies[FIXTURE_NAME].commit

	-- Second install — should reuse the cached repo, lockfile commit unchanged
	pkg:installDependencies()

	local lock2 = json.decode(fs.read(path.join(dir, "lpm-lock.json")))
	local commit2 = lock2.dependencies[FIXTURE_NAME].commit

	test.equal(commit1, commit2)
end)

test.it("installDependencies respects a pinned commit in lpm.json", function()
	-- Get the current HEAD commit first via an unpinned install
	local refDir = makeProjectWithGitDep("git-pin-ref")
	lpm.Package.open(refDir):installDependencies()
	local refLock = json.decode(fs.read(path.join(refDir, "lpm-lock.json")))
	local headCommit = refLock.dependencies[FIXTURE_NAME].commit

	-- Now install a project that pins to that exact commit
	local dir = makeProjectWithGitDep("git-pinned", { commit = headCommit })
	local pkg = lpm.Package.open(dir)
	pkg:installDependencies()

	local lock = json.decode(fs.read(path.join(dir, "lpm-lock.json")))
	test.equal(lock.dependencies[FIXTURE_NAME].commit, headCommit)

	local fixturePath = path.join(dir, "target", FIXTURE_NAME, "init.lua")
	test.truthy(fs.exists(fixturePath))
end)

test.it("rockspec git dep: middleclass can be required after install", function()
	local dir = path.join(tmpBase, "middleclass-consumer")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), [[
		local class = require("middleclass")
		local Animal = class("Animal")
		function Animal:initialize(name) self.name = name end
		local a = Animal("cat")
		assert(a.name == "cat", "expected name 'cat', got " .. tostring(a.name))
	]])
	fs.write(path.join(dir, "lpm.json"), json.encode({
		name = "middleclass-consumer",
		version = "0.1.0",
		dependencies = {
			middleclass = {
				git = "https://github.com/kikito/middleclass",
				branch = "master",
				rockspec = "rockspecs/middleclass-4.1.1-0.rockspec"
			}
		}
	}))

	local pkg = lpm.Package.open(dir)
	pkg:installDependencies()
	pkg:build()

	test.truthy(fs.exists(path.join(dir, "target", "middleclass.lua")))

	local ok, err = pkg:runFile()
	if not ok then print(err) end
	test.truthy(ok)
end)

test.it("rockspec git dep: luafilesystem native C module works", function()
	-- TODO: Re-enable on MacOS when nightly exports LuaJIT symbols.
	if jit.os == "Windows" or jit.os == "OSX" then return end

	local dir = path.join(tmpBase, "lfs-consumer")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), [[
		local lfs = require("lfs")
		local attr = lfs.attributes(".")
		assert(attr ~= nil, "lfs.attributes returned nil")
		assert(attr.mode == "directory", "expected directory, got " .. tostring(attr.mode))
	]])
	fs.write(path.join(dir, "lpm.json"), json.encode({
		name = "lfs-consumer",
		version = "0.1.0",
		dependencies = {
			luafilesystem = {
				git = "https://github.com/lunarmodules/luafilesystem",
				branch = "master"
			}
		}
	}))

	local pkg = lpm.Package.open(dir)
	pkg:installDependencies()
	pkg:build()

	local ok, err = pkg:runFile()
	if not ok then print(err) end
	test.truthy(ok)
end)
