local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")
local process = require("process2")
local git = require("git")

local lde = require("lde-core")

local tmpBase = path.join(env.tmpdir(), "lde-main-tests")

-- Clean up from any previous test run
fs.rmdir(tmpBase)

--
-- runtime.executeFile
--

test.it("runtime.executeFile runs a Lua script", function()
	fs.mkdir(tmpBase)
	local scriptPath = path.join(tmpBase, "hello.lua")
	fs.write(scriptPath, 'return 42')

	local ok, err = lde.runtime.executeFile(scriptPath)
	test.truthy(ok)
end)

test.it("runtime.executeFile returns false for scripts that error", function()
	fs.mkdir(tmpBase)
	local scriptPath = path.join(tmpBase, "fail.lua")
	fs.write(scriptPath, 'error("intentional error")')

	local ok, err = lde.runtime.executeFile(scriptPath)
	test.falsy(ok)
	test.truthy(err)
end)

test.it("runtime.executeFile supports preloaded modules", function()
	fs.mkdir(tmpBase)
	local scriptPath = path.join(tmpBase, "preload.lua")
	fs.write(scriptPath, [[
		local m = require("fake-mod")
		if m.value ~= 123 then
			error("preload failed")
		end
	]])

	local ok, err = lde.runtime.executeFile(scriptPath, {
		preload = {
			["fake-mod"] = function() return { value = 123 } end
		}
	})
	test.truthy(ok)
end)

test.it("runtime.executeFile isolates globals between runs", function()
	fs.mkdir(tmpBase)
	local script1 = path.join(tmpBase, "global1.lua")
	fs.write(script1, 'MY_GLOBAL_VAR = "leaked"')

	local script2 = path.join(tmpBase, "global2.lua")
	fs.write(script2, [[
		if MY_GLOBAL_VAR ~= nil then
			error("global leaked from another script")
		end
	]])

	lde.runtime.executeFile(script1)
	local ok, err = lde.runtime.executeFile(script2)
	test.truthy(ok)
end)

--
-- End-to-end: init + build + verify structure
--

test.it("end-to-end: init, build, and verify package structure", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "e2e-project")
	fs.mkdir(dir)

	local pkg = lde.Package.init(dir)
	test.truthy(pkg)
	test.equal(pkg:getName(), "e2e-project")

	fs.mkdir(pkg:getModulesDir())
	pkg:build()

	test.truthy(fs.exists(pkg:getTargetDir()))
end)

--
-- cwd behavior
--

test.it("runFile: cwd is the package directory", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "cwd-run-test")
	fs.mkdir(dir)

	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "cwd-run-test",
		version = "0.1.0",
		dependencies = {}
	}))

	local srcDir = path.join(dir, "src")
	fs.mkdir(srcDir)
	fs.write(path.join(srcDir, "init.lua"), [[
		local f = assert(io.open("cwd-sentinel.txt", "w"))
		f:close()
	]])

	local pkg = lde.Package.open(dir)
	local ok, err = pkg:runFile(nil, {})
	test.truthy(ok)
	-- sentinel file should be relative to the package dir, not cwd of the test runner
	test.truthy(fs.exists(path.join(dir, "cwd-sentinel.txt")))
end)

test.it("build.lua: cwd is the package directory, not the destination", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "cwd-build-test")
	fs.mkdir(dir)

	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "cwd-build-test",
		version = "0.1.0",
		dependencies = {}
	}))

	local srcDir = path.join(dir, "src")
	fs.mkdir(srcDir)
	fs.write(path.join(srcDir, "init.lua"), 'return true')
	-- build.lua writes a sentinel file relative to cwd
	fs.write(path.join(dir, "build.lua"), [[
		local f = assert(io.open("build-cwd-sentinel.txt", "w"))
		f:close()
	]])

	local pkg = lde.Package.open(dir)
	pkg:build()

	-- sentinel should be in the package dir, not the destination (target/cwd-build-test/)
	test.truthy(fs.exists(path.join(dir, "build-cwd-sentinel.txt")))
	test.falsy(fs.exists(path.join(dir, "target", "cwd-build-test", "build-cwd-sentinel.txt")))
end)

--
-- pkg:runFile with explicit file path
--

test.it("runFile: runs an explicit relative file path", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "runfile-explicit")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), 'return true')
	fs.mkdir(path.join(dir, "scripts"))
	fs.write(path.join(dir, "scripts", "hello.lua"), [[
		local f = assert(io.open("hello-sentinel.txt", "w"))
		f:close()
	]])
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "runfile-explicit",
		version = "0.1.0",
		dependencies = {}
	}))

	local pkg = lde.Package.open(dir)
	local ok, err = pkg:runFile("./scripts/hello.lua")
	test.truthy(ok)
	test.truthy(fs.exists(path.join(dir, "hello-sentinel.txt")))
end)

--
-- pkg:runFile bin field resolution
--

test.it("runFile: uses bin as default entry point when set", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "bin-run-test")
	fs.mkdir(dir)

	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "bin-run-test",
		version = "0.1.0",
		bin = "cli.lua",
		dependencies = {}
	}))

	local srcDir = path.join(dir, "src")
	fs.mkdir(srcDir)
	fs.write(path.join(srcDir, "init.lua"), 'error("should not run init.lua")')
	fs.write(path.join(srcDir, "cli.lua"), 'return true')

	local pkg = lde.Package.open(dir)
	local ok, err = pkg:runFile(nil, {})
	test.truthy(ok)
end)

test.it("runFile: falls back to init.lua when bin is not set", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "bin-run-fallback")
	fs.mkdir(dir)

	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "bin-run-fallback",
		version = "0.1.0",
		dependencies = {}
	}))

	local srcDir = path.join(dir, "src")
	fs.mkdir(srcDir)
	fs.write(path.join(srcDir, "init.lua"), 'return true')

	local pkg = lde.Package.open(dir)
	local ok, err = pkg:runFile(nil, {})
	test.truthy(ok)
end)

--
-- pkg:runScript named script resolution
--

test.it("runScript: runs a named shell command from lde.json scripts", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "run-script-test")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), 'return true')
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "run-script-test",
		version = "0.1.0",
		scripts = { greet = "echo hello" },
		dependencies = {}
	}))

	local pkg = lde.Package.open(dir)
	local ok, output = pkg:runScript("greet", true)
	test.truthy(ok)
	test.truthy(output:find("hello"))
end)


test.it("runScript: errors when script name is not in lde.json", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "run-script-missing")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), 'return true')
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "run-script-missing",
		version = "0.1.0",
		dependencies = {}
	}))

	local pkg = lde.Package.open(dir)
	local ok, err = pcall(function() pkg:runScript("doesnotexist") end)
	test.falsy(ok)
	test.includes(err, "doesnotexist")
end)

--
-- End-to-end: init + build + verify structure
--

test.it("git dep: installs root package, not a sub-package, when repo has lde.json at root and in subdirs", function()
	fs.mkdir(tmpBase)

	-- Simulate a cloned git repo that has lde.json at root AND in subdirectories.
	-- This reproduces the bug where the sub-package (e.g. "ansi") was installed
	-- instead of the root package (e.g. "lde-test").
	--
	-- We pre-populate the real git cache dir so getOrInitGitRepo skips cloning.
	local repoDir = lde.global.getGitRepoDir("my-root-pkg")
	fs.rmdir(repoDir)
	fs.mkdir(repoDir)

	-- Initialize the git repo so commit info can be fetched
	git.init(repoDir, true)

	-- Root lde.json
	fs.write(path.join(repoDir, "lde.json"), json.encode({
		name = "my-root-pkg",
		version = "1.0.0",
		dependencies = {}
	}))
	fs.mkdir(path.join(repoDir, "src"))
	fs.write(path.join(repoDir, "src", "init.lua"), "return {}")

	-- Subdirectory packages (these would be found first by fs.scan's "**/" pattern)
	local subDir = path.join(repoDir, "packages", "ansi")
	fs.mkdir(path.join(repoDir, "packages"))
	fs.mkdir(subDir)
	fs.write(path.join(subDir, "lde.json"), json.encode({
		name = "ansi",
		version = "0.1.0",
		dependencies = {}
	}))
	fs.mkdir(path.join(subDir, "src"))
	fs.write(path.join(subDir, "src", "init.lua"), "return {}")

	-- App that depends on the root package via git
	local appDir = path.join(tmpBase, "git-dep-app")
	fs.mkdir(appDir)
	fs.mkdir(path.join(appDir, "src"))
	fs.write(path.join(appDir, "src", "init.lua"), "return {}")
	fs.write(path.join(appDir, "lde.json"), json.encode({
		name = "git-dep-app",
		version = "0.1.0",
		dependencies = {
			["my-root-pkg"] = { git = "https://example.com/my-root-pkg.git" }
		}
	}))

	local app = lde.Package.open(appDir)
	app:installDependencies()

	-- Should install "my-root-pkg", NOT "ansi"
	test.truthy(fs.exists(path.join(appDir, "target", "my-root-pkg")))
	test.falsy(fs.exists(path.join(appDir, "target", "ansi")))

	fs.rmdir(repoDir)
end)

test.it("end-to-end: package with dependency can install and build", function()
	fs.mkdir(tmpBase)

	local libDir = path.join(tmpBase, "e2e-lib")
	fs.mkdir(libDir)
	fs.mkdir(path.join(libDir, "src"))
	fs.write(path.join(libDir, "src", "init.lua"), 'return { greet = function() return "hi" end }')
	fs.write(path.join(libDir, "lde.json"), json.encode({
		name = "e2e-lib",
		version = "0.1.0",
		dependencies = {}
	}))

	local appDir = path.join(tmpBase, "e2e-app")
	fs.mkdir(appDir)
	fs.mkdir(path.join(appDir, "src"))
	fs.write(path.join(appDir, "src", "init.lua"), 'local lib = require("e2e-lib"); return lib.greet()')
	fs.write(path.join(appDir, "lde.json"), json.encode({
		name = "e2e-app",
		version = "0.1.0",
		dependencies = {
			["e2e-lib"] = { path = "../e2e-lib" }
		}
	}))

	local app = lde.Package.open(appDir)
	test.truthy(app)

	app:installDependencies()
	app:build()

	test.truthy(fs.exists(path.join(appDir, "target", "e2e-lib", "init.lua")))
	test.truthy(fs.exists(path.join(appDir, "target", "e2e-app")))
end)

test.it("installDependencies: errors when two deps share a name but have different sources", function()
	fs.mkdir(tmpBase)

	-- Two physically different packages both named "shared-lib"
	local libDirA = path.join(tmpBase, "conflict-lib-a")
	local libDirB = path.join(tmpBase, "conflict-lib-b")
	for _, dir in ipairs({ libDirA, libDirB }) do
		fs.mkdir(dir)
		fs.mkdir(path.join(dir, "src"))
		fs.write(path.join(dir, "src", "init.lua"), "return {}")
		fs.write(path.join(dir, "lde.json"), json.encode({
			name = "shared-lib",
			version = "0.1.0",
			dependencies = {}
		}))
	end

	-- Middle package depends on lib-a's "shared-lib"
	local middleDir = path.join(tmpBase, "conflict-middle")
	fs.mkdir(middleDir)
	fs.mkdir(path.join(middleDir, "src"))
	fs.write(path.join(middleDir, "src", "init.lua"), "return {}")
	fs.write(path.join(middleDir, "lde.json"), json.encode({
		name = "conflict-middle",
		version = "0.1.0",
		dependencies = {
			["shared-lib"] = { path = "../conflict-lib-a" }
		}
	}))

	-- Root depends on middle (which pulls in lib-a) AND directly on lib-b under the same name
	local rootDir = path.join(tmpBase, "conflict-root")
	fs.mkdir(rootDir)
	fs.mkdir(path.join(rootDir, "src"))
	fs.write(path.join(rootDir, "src", "init.lua"), "return {}")
	fs.write(path.join(rootDir, "lde.json"), json.encode({
		name = "conflict-root",
		version = "0.1.0",
		dependencies = {
			["conflict-middle"] = { path = "../conflict-middle" },
			["shared-lib"]      = { path = "../conflict-lib-b" }
		}
	}))

	local root = lde.Package.open(rootDir)
	local ok, err = pcall(function() root:installDependencies() end)
	test.falsy(ok)
	test.includes(err, "shared-lib")
end)

test.it("installDependencies: writes a single flat lockfile containing all transitive deps", function()
	fs.mkdir(tmpBase)

	-- Deep dep (no dependencies)
	local deepDir = path.join(tmpBase, "flat-lock-deep")
	fs.mkdir(deepDir)
	fs.mkdir(path.join(deepDir, "src"))
	fs.write(path.join(deepDir, "src", "init.lua"), "return {}")
	fs.write(path.join(deepDir, "lde.json"), json.encode({
		name = "flat-lock-deep",
		version = "0.1.0",
		dependencies = {}
	}))

	-- Middle dep depends on deep
	local middleDir = path.join(tmpBase, "flat-lock-middle")
	fs.mkdir(middleDir)
	fs.mkdir(path.join(middleDir, "src"))
	fs.write(path.join(middleDir, "src", "init.lua"), "return {}")
	fs.write(path.join(middleDir, "lde.json"), json.encode({
		name = "flat-lock-middle",
		version = "0.1.0",
		dependencies = {
			["flat-lock-deep"] = { path = "../flat-lock-deep" }
		}
	}))

	-- Root depends only on middle
	local rootDir = path.join(tmpBase, "flat-lock-root")
	fs.mkdir(rootDir)
	fs.mkdir(path.join(rootDir, "src"))
	fs.write(path.join(rootDir, "src", "init.lua"), "return {}")
	fs.write(path.join(rootDir, "lde.json"), json.encode({
		name = "flat-lock-root",
		version = "0.1.0",
		dependencies = {
			["flat-lock-middle"] = { path = "../flat-lock-middle" }
		}
	}))

	local root = lde.Package.open(rootDir)
	root:installDependencies()

	-- Root lockfile must contain both middle AND deep
	local lockfile = root:readLockfile()
	test.truthy(lockfile)
	test.truthy(lockfile:getDependency("flat-lock-middle"))
	test.truthy(lockfile:getDependency("flat-lock-deep"))

	-- No lockfile should have been written inside the middle dep
	test.falsy(lde.Lockfile.open(path.join(middleDir, "lde.lock")))
end)

-- It's undefined behavior for lde specifically to rely on transitive deps.
-- But regardless need to ensure it works at runtime for the actual dependencies that will use it.
test.it("transitive dep: util is resolvable as a dependency of lde-core", function()
	local util = require("util")
	test.truthy(util)
	test.truthy(util.dedent)
end)

test.it("runFile: errors with a clear message when package has no bin and no init.lua", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "no-entrypoint")
	fs.mkdir(dir)

	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "no-entrypoint",
		version = "0.1.0",
		dependencies = {}
	}))

	-- src/ exists but has no init.lua — simulates a library-only rockspec package
	local srcDir = path.join(dir, "src")
	fs.mkdir(srcDir)
	fs.write(path.join(srcDir, "lib.lua"), 'return {}')

	local pkg = lde.Package.open(dir)
	local ok, err = pkg:runFile(nil, {})
	test.falsy(ok)
	test.includes(err, "no runnable entry point")
	test.includes(err, "no-entrypoint")
end)

test.skipIf(jit.os ~= "Linux")("archive dep: installs a .tar.gz dependency from a URL", function()
	fs.mkdir(tmpBase)
	local appDir = path.join(tmpBase, "archive-dep-app")
	fs.mkdir(appDir)
	fs.mkdir(path.join(appDir, "src"))
	fs.write(path.join(appDir, "src", "init.lua"), "return {}")
	fs.write(path.join(appDir, "lde.json"), json.encode({
		name = "archive-dep-app",
		version = "0.1.0",
		dependencies = {
			["lua-term"] = {
				archive = "https://github.com/hoelzro/lua-term/archive/0.08.tar.gz",
				rockspec = "lua-term-0.8-1.rockspec"
			}
		}
	}))

	local app = lde.Package.open(appDir)
	app:installDependencies()

	test.truthy(fs.isdir(path.join(appDir, "target", "term")))
end)
