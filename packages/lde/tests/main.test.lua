local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")
local git2 = require("git2-sys")

local lde = require("lde-core")

local ldecli = require("tests.lib.ldecli")

test.it("should not ignore --git in ldx", function()
	local cloneUrl = "https://github.com/codebycruz/hood"

	-- Resolve the real commit so the cache key matches what getOrCloneRepo expects.
	local commit = assert(git2.lsRemote(cloneUrl, "HEAD"))

	-- Pre-populate the cache with a fake repo that lacks a "triangle" package.
	local repoDir = lde.global.getGitRepoDir("hood", commit)
	fs.rmdir(repoDir)
	fs.mkdir(repoDir)
	fs.write(path.join(repoDir, "lde.json"), json.encode({
		name = "hood",
		version = "1.0.0",
		dependencies = {}
	}))
	fs.mkdir(path.join(repoDir, "src"))
	fs.write(path.join(repoDir, "src", "init.lua"), "")

	local _, out = ldecli { "x", "triangle", "--git", cloneUrl }
	test.falsy(out:find("not found in lde registry"))
	test.includes(out, "No package named 'triangle'")

	fs.rmdir(repoDir)
end)

-- TODO: Figure out why android struggles with cli tests
local isAndroid = env.var("ANDROID_ROOT") ~= nil

test.skipIf(isAndroid)("lde test skips packages with no tests/ directory", function()
	local tmpDir = path.join(env.tmpdir(), "lde-test-skip-test")
	fs.rmdir(tmpDir)
	fs.mkdir(tmpDir)

	-- Package with tests/
	local withTests = path.join(tmpDir, "with-tests")
	fs.mkdir(withTests)
	fs.mkdir(path.join(withTests, "src"))
	fs.mkdir(path.join(withTests, "tests"))
	fs.write(path.join(withTests, "src", "init.lua"), "return true")
	fs.write(path.join(withTests, "lde.json"), json.encode({ name = "with-tests", version = "0.1.0" }))
	fs.write(path.join(withTests, "tests", "dummy.test.lua"), [[
		local test = require("lde-test")
		test.it("dummy passes", function() end)
	]])

	-- Package without tests/ (has a dep that would get installed if erroneously picked up)
	local noTests = path.join(tmpDir, "no-tests")
	fs.mkdir(noTests)
	fs.mkdir(path.join(noTests, "src"))
	fs.write(path.join(noTests, "src", "init.lua"), "return true")
	fs.write(path.join(noTests, "lde.json"), json.encode({
		name = "no-tests",
		version = "0.1.0"
	}))

	local ok, out = ldecli({ "test" }, tmpDir)
	test.truthy(ok)
	test.includes(out, "dummy passes")
	-- The package without tests/ should not appear in output at all
	test.falsy(out:find("no%-tests", 1, false))

	fs.rmdir(tmpDir)
end)

test.it("--tree overrides the global lde directory", function()
	local tmpTree = path.join(env.tmpdir(), "lde-tree-test")
	fs.rmdir(tmpTree)

	ldecli { "--tree", tmpTree, "--version" }

	test.truthy(fs.exists(tmpTree))
	test.truthy(fs.exists(path.join(tmpTree, "git")))
end)

test.skipIf(isAndroid)("-C changes the working directory before loose-file resolution", function()
	local tmpDir = path.join(env.tmpdir(), "lde-cli-cwd-short")
	local pkgDir = path.join(tmpDir, "pkg")
	fs.rmdir(tmpDir)
	fs.mkdir(tmpDir)
	fs.mkdir(pkgDir)
	fs.write(path.join(pkgDir, "hello.lua"), 'io.write("cwd-short")')

	local ok, out = ldecli({ "-C", "pkg", "hello.lua" }, tmpDir)
	test.truthy(ok)
	test.includes(out, "cwd-short")

	fs.rmdir(tmpDir)
end)

test.skipIf(isAndroid)("--cwd changes the working directory before package resolution", function()
	local tmpDir = path.join(env.tmpdir(), "lde-cli-cwd-long")
	local pkgDir = path.join(tmpDir, "pkg")
	fs.rmdir(tmpDir)
	fs.mkdir(tmpDir)
	fs.mkdir(pkgDir)
	fs.mkdir(path.join(pkgDir, "src"))
	fs.write(path.join(pkgDir, "src", "init.lua"), 'io.write("cwd-long")')
	fs.write(path.join(pkgDir, "lde.json"), json.encode({
		name = "cwd-long",
		version = "0.1.0"
	}))

	local ok, out = ldecli({ "--cwd", "pkg", "run" }, tmpDir)
	test.truthy(ok)
	test.includes(out, "cwd-long")

	fs.rmdir(tmpDir)
end)

test.it("--cwd errors when the target directory does not exist", function()
	local tmpDir = path.join(env.tmpdir(), "lde-cli-cwd-missing")
	fs.rmdir(tmpDir)
	fs.mkdir(tmpDir)

	local ok, out = ldecli({ "--cwd", "missing", "--version" }, tmpDir)
	test.falsy(ok)
	test.includes(out, "Directory does not exist")

	fs.rmdir(tmpDir)
end)

-- TODO: re-enable once a nightly build with TMPDIR set in the Android Docker run is available
test.skipIf(env.var("ANDROID_ROOT") ~= nil)("lde <script> <args> passes positional args to the script", function()
	local script = path.join(env.tmpdir(), "lde-argtest.lua")
	fs.write(script, 'io.write(arg[1] .. " " .. arg[2])')

	local ok, out = ldecli { script, "hello", "world" }
	test.truthy(ok)
	test.includes(out, "hello world")
end)

-- TODO: re-enable once a nightly build with TMPDIR set in the Android Docker run is available
test.skipIf(env.var("ANDROID_ROOT") ~= nil)("lde <script> receives arg[0] as the script path", function()
	local script = path.join(env.tmpdir(), "lde-arg0test.lua")
	fs.write(script, "io.write(arg[0])")

	local ok, out = ldecli { script }
	test.truthy(ok)
	test.includes(out, script)
end)
