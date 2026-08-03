local test = require("lde-test")

local lde = require("lde-core")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")
local process = require("process")

local tmpBase = path.join(env.tmpdir(), "lde-build-tests")

-- Clean up from any previous test run
fs.rmdir(tmpBase)

--- Creates a package with src directory and source files.
local function makePackageWithSrc(name, srcFiles, config)
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, name)
	fs.mkdir(dir)

	config = config or {
		name = name,
		version = "0.1.0",
		dependencies = {}
	}

	fs.write(path.join(dir, "lde.json"), json.encode(config))

	local srcDir = path.join(dir, "src")
	fs.mkdir(srcDir)
	fs.mkdir(path.join(dir, "target"))

	for filename, content in pairs(srcFiles) do
		fs.write(path.join(srcDir, filename), content)
	end

	return dir
end

--
-- Package:build (symlink-based, no build script)
--

test.it("Package:build creates a symlink in target/<name>", function()
	local dir = makePackageWithSrc("build-basic", {
		["init.lua"] = 'return "hello"'
	})

	local pkg = lde.Package.open(dir)
	pkg:build()

	local targetDir = pkg:getTargetDir()
	test.truthy(fs.exists(targetDir))
end)

test.it("Package:build target contains the source files", function()
	local dir = makePackageWithSrc("build-contents", {
		["init.lua"] = 'return { version = "1.0" }',
		["helper.lua"] = 'return {}'
	})

	local pkg = lde.Package.open(dir)
	pkg:build()

	local targetDir = pkg:getTargetDir()
	test.truthy(fs.exists(path.join(targetDir, "init.lua")))
	test.truthy(fs.exists(path.join(targetDir, "helper.lua")))
end)

test.it("Package:build is idempotent (can be called twice)", function()
	local dir = makePackageWithSrc("build-idempotent", {
		["init.lua"] = 'return true'
	})

	local pkg = lde.Package.open(dir)
	pkg:build()
	pkg:build()

	test.truthy(fs.exists(pkg:getTargetDir()))
end)

--
-- Package:build input invalidation (build.lua packages)
--

test.it("build script is skipped when src/, lde.json, and build.lua are unchanged", function()
	local dir = makePackageWithSrc("build-skip-unchanged", {
		["init.lua"] = 'return 1'
	})

	-- Each run appends a marker; if the script were re-run the marker would grow.
	fs.write(path.join(dir, "build.lua"), [[
local f = assert(io.open("build-count.txt", "a"))
f:write("x")
f:close()
]])

	local pkg = lde.Package.open(dir)
	pkg:build()
	pkg:build()
	pkg:build()

	test.equal(fs.read(path.join(dir, "build-count.txt")), "x")
	-- the stamp records the input state inside the output dir
	test.truthy(fs.exists(path.join(dir, "target", pkg:getName(), ".lde-build-stamp")))
end)

test.it("build script is re-run when a src file changes", function()
	local dir = makePackageWithSrc("build-rerun-src", {
		["init.lua"] = 'return 1'
	})

	fs.write(path.join(dir, "build.lua"), [[
local f = assert(io.open("build-count-src.txt", "a"))
f:write("x")
f:close()
]])

	local pkg = lde.Package.open(dir)
	pkg:build()
	-- Different size so the mtime/size fast path can't mask the change.
	fs.write(path.join(dir, "src", "init.lua"), 'return 123456')
	pkg:build()

	test.equal(fs.read(path.join(dir, "build-count-src.txt")), "xx")
end)

test.it("build script is re-run when lde.json changes", function()
	local dir = makePackageWithSrc("build-rerun-config", {
		["init.lua"] = 'return 1'
	})

	fs.write(path.join(dir, "build.lua"), [[
local f = assert(io.open("build-count-config.txt", "a"))
f:write("x")
f:close()
]])

	local pkg = lde.Package.open(dir)
	pkg:build()

	-- Rewrite with a clearly larger config so the mtime/size fast path can't mask it.
	fs.write(path.join(dir, "lde.json"), json.encode({
		name        = "build-rerun-config",
		version     = "0.20.0",
		description = "a longer config to change the file size",
		dependencies = {}
	}))
	pkg:build()

	test.equal(fs.read(path.join(dir, "build-count-config.txt")), "xx")
end)

test.it("build script is re-run when build.lua itself changes", function()
	local dir = makePackageWithSrc("build-rerun-script", {
		["init.lua"] = 'return 1'
	})

	fs.write(path.join(dir, "build.lua"), [[
local f = assert(io.open("build-count-script.txt", "a"))
f:write("x")
f:close()
]])

	local pkg = lde.Package.open(dir)
	pkg:build()

	-- Longer script: changes the size so the mtime/size fast path can't mask it.
	fs.write(path.join(dir, "build.lua"), [[
local f = assert(io.open("build-count-script.txt", "a"))
f:write("y")
f:close()
-- extra line to change the file size
]])
	pkg:build()

	test.equal(fs.read(path.join(dir, "build-count-script.txt")), "xy")
end)

--
-- Package:installDependencies with path dependencies
--

test.it("installDependencies installs a local path dependency", function()
	local depDir = makePackageWithSrc("install-dep", {
		["init.lua"] = 'return { name = "install-dep" }'
	})

	local mainDir = path.join(tmpBase, "install-main")
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')

	fs.write(path.join(mainDir, "lde.json"), json.encode({
		name = "install-main",
		version = "0.1.0",
		dependencies = {
			["install-dep"] = { path = "../install-dep" }
		}
	}))

	local pkg = lde.Package.open(mainDir)
	pkg:installDependencies()

	local depInTarget = path.join(mainDir, "target", "install-dep")
	test.truthy(fs.exists(depInTarget))
	test.truthy(fs.exists(path.join(depInTarget, "init.lua")))
end)

test.it("installDependencies installs multiple dependencies", function()
	makePackageWithSrc("multi-dep-a", {
		["init.lua"] = 'return "a"'
	})

	makePackageWithSrc("multi-dep-b", {
		["init.lua"] = 'return "b"'
	})

	local mainDir = path.join(tmpBase, "multi-main")
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')

	fs.write(path.join(mainDir, "lde.json"), json.encode({
		name = "multi-main",
		version = "0.1.0",
		dependencies = {
			["multi-dep-a"] = { path = "../multi-dep-a" },
			["multi-dep-b"] = { path = "../multi-dep-b" }
		}
	}))

	local pkg = lde.Package.open(mainDir)
	pkg:installDependencies()

	test.truthy(fs.exists(path.join(mainDir, "target", "multi-dep-a", "init.lua")))
	test.truthy(fs.exists(path.join(mainDir, "target", "multi-dep-b", "init.lua")))
end)

test.it("installDependencies skips already-installed symlink dependencies", function()
	makePackageWithSrc("skip-dep", {
		["init.lua"] = 'return "skip"'
	})

	local mainDir = path.join(tmpBase, "skip-main")
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')

	fs.write(path.join(mainDir, "lde.json"), json.encode({
		name = "skip-main",
		version = "0.1.0",
		dependencies = {
			["skip-dep"] = { path = "../skip-dep" }
		}
	}))

	local pkg = lde.Package.open(mainDir)
	pkg:installDependencies()
	pkg:installDependencies()

	test.truthy(fs.exists(path.join(mainDir, "target", "skip-dep")))
end)

--
-- Lockfile
--

test.it("installDependencies writes a lockfile with resolved path dependency", function()
	makePackageWithSrc("lockfile-dep", {
		["init.lua"] = 'return "lockfile-dep"'
	})

	local mainDir = path.join(tmpBase, "lockfile-main")
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')
	fs.write(path.join(mainDir, "lde.json"), json.encode({
		name = "lockfile-main",
		version = "0.1.0",
		dependencies = {
			["lockfile-dep"] = { path = "../lockfile-dep" }
		}
	}))

	local pkg = lde.Package.open(mainDir)
	pkg:installDependencies()

	local lockPath = path.join(mainDir, "lde.lock")
	test.truthy(fs.exists(lockPath))

	local content = json.decode(fs.read(lockPath))
	test.equal(content.version, "1")
	test.equal(content.dependencies["lockfile-dep"].path, "../lockfile-dep")
end)

test.it("installDependencies uses lockfile to pin dependency on reinstall", function()
	makePackageWithSrc("pinned-dep", {
		["init.lua"] = 'return "pinned"'
	})
	makePackageWithSrc("other-dep", {
		["init.lua"] = 'return "other"'
	})

	local mainDir = path.join(tmpBase, "pinned-main")
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')
	fs.write(path.join(mainDir, "lde.json"), json.encode({
		name = "pinned-main",
		version = "0.1.0",
		dependencies = {
			["pinned-dep"] = { path = "../pinned-dep" }
		}
	}))

	local pkg = lde.Package.open(mainDir)
	pkg:installDependencies()

	-- Manually overwrite the lockfile to point at other-dep instead
	lde.Lockfile.new(path.join(mainDir, "lde.lock"), {
		["pinned-dep"] = { path = "../other-dep" }
	}):save()

	-- Remove the installed symlink/junction so reinstall actually runs
	fs.rmdir(path.join(mainDir, "target", "pinned-dep"))

	-- Reinstall — should use the lockfile's path, getting other-dep's init.lua
	pkg:installDependencies()

	local content = fs.read(path.join(mainDir, "target", "pinned-dep", "init.lua"))
	test.equal(content, 'return "other"')
end)

--
-- Transitive dependencies
--

test.it("installDependencies installs transitive dependencies", function()
	makePackageWithSrc("leaf-dep", {
		["init.lua"] = 'return "leaf"'
	})

	local midDir = path.join(tmpBase, "mid-dep")
	fs.mkdir(midDir)
	fs.mkdir(path.join(midDir, "src"))
	fs.write(path.join(midDir, "src", "init.lua"), 'return require("leaf-dep")')

	fs.write(path.join(midDir, "lde.json"), json.encode({
		name = "mid-dep",
		version = "0.1.0",
		dependencies = {
			["leaf-dep"] = { path = "../leaf-dep" }
		}
	}))

	local rootDir = path.join(tmpBase, "trans-root")
	fs.mkdir(rootDir)
	fs.mkdir(path.join(rootDir, "src"))
	fs.write(path.join(rootDir, "src", "init.lua"), 'return true')

	fs.write(path.join(rootDir, "lde.json"), json.encode({
		name = "trans-root",
		version = "0.1.0",
		dependencies = {
			["mid-dep"] = { path = "../mid-dep" }
		}
	}))

	local pkg = lde.Package.open(rootDir)
	pkg:installDependencies()

	test.truthy(fs.exists(path.join(rootDir, "target", "mid-dep")))
	test.truthy(fs.exists(path.join(rootDir, "target", "leaf-dep")))
end)

-- Regression: path deps pointing to the same package from different relative starting
-- points must not be treated as conflicts.
test.it("installDependencies does not conflict when two deps reference the same path package differently", function()
	-- shared-dep is referenced by both root (../shared-dep) and mid (../shared-dep, same abs path)
	makePackageWithSrc("shared-dep", { ["init.lua"] = 'return "shared"' })

	-- mid-dep lives one level deeper inside a subdir so its relative path differs
	local midDir = path.join(tmpBase, "conflict-mid")
	fs.mkdir(midDir)
	fs.mkdir(path.join(midDir, "src"))
	fs.write(path.join(midDir, "src", "init.lua"), 'return true')
	fs.write(path.join(midDir, "lde.json"), json.encode({
		name = "conflict-mid",
		version = "0.1.0",
		dependencies = {
			["shared-dep"] = { path = "../shared-dep" }
		}
	}))

	local rootDir = path.join(tmpBase, "conflict-root")
	fs.mkdir(rootDir)
	fs.mkdir(path.join(rootDir, "src"))
	fs.write(path.join(rootDir, "src", "init.lua"), 'return true')
	fs.write(path.join(rootDir, "lde.json"), json.encode({
		name = "conflict-root",
		version = "0.1.0",
		dependencies = {
			["shared-dep"] = { path = "../shared-dep" },
			["conflict-mid"] = { path = "../conflict-mid" }
		}
	}))

	local pkg = lde.Package.open(rootDir)
	-- Should not error
	pkg:installDependencies()

	test.truthy(fs.exists(path.join(rootDir, "target", "shared-dep")))
end)

--
-- Rockspec buildfn: init.lua module mapping regression
--

test.it("rockspec buildfn installs init.lua modules as dir/init.lua not dir.lua", function()
	-- Minimal rockspec with a module that maps to an init.lua (like luacheck.vendor.sha1)
	local rockspecContent = [[
package = "mypkg"
version = "1.0-1"
source = { url = "https://example.com" }
build = {
  type = "builtin",
  modules = {
    ["mypkg"] = "src/init.lua",
    ["mypkg.sub"] = "src/sub/init.lua",
    ["mypkg.sub.leaf"] = "src/sub/leaf.lua",
  }
}
]]

	local dir = path.join(tmpBase, "rockspec-init-regression")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.mkdir(path.join(dir, "src", "sub"))
	fs.write(path.join(dir, "mypkg-1.0-1.rockspec"), rockspecContent)
	fs.write(path.join(dir, "src", "init.lua"), 'return "mypkg"')
	fs.write(path.join(dir, "src", "sub", "init.lua"), 'return "sub"')
	fs.write(path.join(dir, "src", "sub", "leaf.lua"), 'return "leaf"')

	local pkg = lde.Package.openRockspec(dir)
	test.truthy(pkg)

	local outputDir = path.join(dir, "target", "mypkg")
	local ok2, err = pkg:runBuildScript(outputDir)
	test.truthy(ok2, err)

	local modulesDir = path.join(dir, "target")
	-- mypkg -> src/init.lua => should be mypkg/init.lua, NOT mypkg.lua
	test.truthy(fs.exists(path.join(modulesDir, "mypkg", "init.lua")))
	test.equal(fs.exists(path.join(modulesDir, "mypkg.lua")), false)
	-- mypkg.sub -> src/sub/init.lua => mypkg/sub/init.lua
	test.truthy(fs.exists(path.join(modulesDir, "mypkg", "sub", "init.lua")))
	-- mypkg.sub.leaf -> src/sub/leaf.lua => mypkg/sub/leaf.lua
	test.truthy(fs.exists(path.join(modulesDir, "mypkg", "sub", "leaf.lua")))
end)

test.it("rockspec buildfn: module key ending in .init installs as dir/init.lua (luasystem pattern)", function()
	local rockspecContent = [[
package = "mysystem"
version = "1.0-1"
source = { url = "https://example.com" }
build = {
  type = "builtin",
  modules = {
    ["system.init"] = "system/init.lua",
  }
}
]]

	local dir = path.join(tmpBase, "rockspec-dotinit-regression")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "system"))
	fs.write(path.join(dir, "mysystem-1.0-1.rockspec"), rockspecContent)
	fs.write(path.join(dir, "system", "init.lua"), 'return "system"')

	local pkg = lde.Package.openRockspec(dir)
	test.truthy(pkg)

	local outputDir = path.join(dir, "target", "mysystem")
	local ok, err = pkg:runBuildScript(outputDir)
	test.truthy(ok, err)

	local modulesDir = path.join(dir, "target")
	-- system.init -> system/init.lua => should be at target/system/init.lua
	test.truthy(fs.exists(path.join(modulesDir, "system", "init.lua")))
	-- must NOT be at target/system/init/init.lua
	test.equal(fs.exists(path.join(modulesDir, "system", "init", "init.lua")), false)
end)

test.it("rockspec: platform lua modules are not misclassified as native modules", function()
	local platKey = jit.os == "OSX" and "macosx" or jit.os == "Windows" and "win32" or "linux"

	local rockspecContent = string.format([[
package = "mypkg"
version = "1.0-1"
source = { url = "https://example.com" }
build = {
  type = "builtin",
  modules = {
    ["mypkg.http"] = "src/http.lua",
    ["mypkg.core"] = { sources = { "src/core.c" } },
  },
  platforms = {
    ["%s"] = {
      modules = {
        ["mypkg.extra"] = "src/extra.lua",
        ["mypkg.native"] = { sources = { "src/native.c" } },
      }
    }
  }
}
]], platKey)

	local dir = path.join(tmpBase, "rockspec-module-classify")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "mypkg-1.0-1.rockspec"), rockspecContent)
	fs.write(path.join(dir, "src", "http.lua"), 'return "http"')
	fs.write(path.join(dir, "src", "extra.lua"), 'return "extra"')

	local pkg = lde.Package.openRockspec(dir)
	test.truthy(pkg)

	local outputDir = path.join(dir, "target", "mypkg")
	pkg:runBuildScript(outputDir) -- may fail on C compile, that's ok

	local modulesDir = path.join(dir, "target")
	-- lua modules must be copied as .lua files, not passed to gcc
	test.truthy(fs.exists(path.join(modulesDir, "mypkg", "http.lua")))
	test.truthy(fs.exists(path.join(modulesDir, "mypkg", "extra.lua")))
	-- must NOT exist as .so (would mean they were misclassified as native)
	test.equal(fs.exists(path.join(modulesDir, "mypkg", "http.so")), false)
	test.equal(fs.exists(path.join(modulesDir, "mypkg", "extra.so")), false)
end)

--
-- runTests: target/tests setup
--

local testFixture = 'return { magic = 42 }'
local testFile = [[
local t = require("lde-test")
local fixture = require("tests.fixture")
t.it("can require tests.fixture", function()
	t.equal(fixture.magic, 42)
end)
]]

test.it("runTests can require tests.fixture without build script", function()
	local dir = makePackageWithSrc("runtests-symlink", { ["init.lua"] = 'return true' })

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "fixture.lua"), testFixture)
	fs.write(path.join(testsDir, "main.test.lua"), testFile)

	local pkg = lde.Package.open(dir)
	local results = pkg:runTests()

	test.equal(results.failures, 0)
	test.equal(results.error, nil)
end)

test.it("runTests can require tests.fixture with build script", function()
	local dir = makePackageWithSrc("runtests-copy", { ["init.lua"] = 'return true' })

	local f = io.open(path.join(dir, "build.lua"), "w")
	f:write('local f = io.open(os.getenv("LDE_OUTPUT_DIR") .. "/init.lua", "w"); f:write("return true"); f:close()')
	f:close()

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "fixture.lua"), testFixture)
	fs.write(path.join(testsDir, "main.test.lua"), testFile)

	local pkg = lde.Package.open(dir)
	local results = pkg:runTests()

	test.equal(results.failures, 0)
	test.equal(results.error, nil)
end)

test.it("runTests fails when a test file registers no tests", function()
	local dir = makePackageWithSrc("runtests-empty", { ["init.lua"] = 'return true' })

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "empty.test.lua"), 'local t = require("lde-test")')

	local pkg = lde.Package.open(dir)
	local results = pkg:runTests()

	test.equal(results.failures, 1)
	test.equal(results.total, 1)
	test.equal(#results.files, 1)
	test.equal(results.files[1].error, "No tests were registered")
end)

--
-- runTests: file filter globs
--

local filterTestFile = [[
local t = require("lde-test")
t.it("runs", function() end)
]]

test.it("runTests with single filter runs only matching files", function()
	local dir = makePackageWithSrc("runtests-filter-single", { ["init.lua"] = 'return true' })

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "foo.test.lua"), filterTestFile)
	fs.write(path.join(testsDir, "bar.test.lua"), filterTestFile)
	fs.write(path.join(testsDir, "baz.test.lua"), filterTestFile)

	local pkg = lde.Package.open(dir)
	local results = pkg:runTests(nil, { "foo*" })

	test.equal(results.failures, 0)
	test.equal(#results.files, 1)
	test.equal(results.files[1].file, "foo.test.lua")
end)

test.it("runTests with multiple filters runs matching files (OR logic)", function()
	local dir = makePackageWithSrc("runtests-filter-multi", { ["init.lua"] = 'return true' })

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "alpha.test.lua"), filterTestFile)
	fs.write(path.join(testsDir, "beta.test.lua"), filterTestFile)
	fs.write(path.join(testsDir, "gamma.test.lua"), filterTestFile)

	local pkg = lde.Package.open(dir)
	local results = pkg:runTests(nil, { "alpha*", "*gamma*" })

	test.equal(results.failures, 0)
	test.equal(#results.files, 2)
	test.equal(results.total, 2)
end)

test.it("runTests with filter that matches nothing returns empty results", function()
	local dir = makePackageWithSrc("runtests-filter-empty", { ["init.lua"] = 'return true' })

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "main.test.lua"), filterTestFile)

	local pkg = lde.Package.open(dir)
	local results = pkg:runTests(nil, { "doesnot*exist*" })

	test.equal(results.failures, 0)
	test.equal(#results.files, 0)
	test.equal(results.total, 0)
end)

test.it("runTests without filters runs all test files", function()
	local dir = makePackageWithSrc("runtests-filter-none", { ["init.lua"] = 'return true' })

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "a.test.lua"), filterTestFile)
	fs.write(path.join(testsDir, "b.test.lua"), filterTestFile)

	local pkg = lde.Package.open(dir)
	local results = pkg:runTests()

	test.equal(results.failures, 0)
	test.equal(#results.files, 2)
	test.equal(results.total, 2)
end)

test.it("runTests with absolute path filter runs only that file", function()
	local dir = makePackageWithSrc("runtests-filter-abspath", { ["init.lua"] = 'return true' })

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "ohyes.test.lua"), filterTestFile)
	fs.write(path.join(testsDir, "ohno.test.lua"), filterTestFile)

	local absPath = path.join(testsDir, "ohyes.test.lua")
	local pkg = lde.Package.open(dir)
	local results = pkg:runTests(nil, { absPath })

	test.equal(results.failures, 0)
	test.equal(#results.files, 1)
	test.equal(results.files[1].file, "ohyes.test.lua")
end)

test.it("runTests with path-like filter containing glob resolves and matches", function()
	local dir = makePackageWithSrc("runtests-filter-pathglob", { ["init.lua"] = 'return true' })

	local testsDir = path.join(dir, "tests")
	local subDir = path.join(testsDir, "sub")
	fs.mkdir(testsDir)
	fs.mkdir(subDir)
	fs.write(path.join(testsDir, "one.test.lua"), filterTestFile)
	fs.write(path.join(subDir, "two.test.lua"), filterTestFile)

	local globPath = path.join(testsDir, "sub", "*.test.lua")
	local pkg = lde.Package.open(dir)
	local results = pkg:runTests(nil, { globPath })

	test.equal(results.failures, 0)
	test.equal(#results.files, 1)
	test.equal(results.files[1].file, "sub" .. path.separator .. "two.test.lua")
end)

test.it(
	"rockspec buildfn: array-style sources table compiles native module", function()
		local rockDir = path.join(tmpBase, "array-sources-rock")
		fs.mkdir(rockDir)
		fs.mkdir(path.join(rockDir, "src"))
		fs.write(path.join(rockDir, "src", "greet.c"), [[
#include <stddef.h>
typedef struct lua_State lua_State;
typedef int (*lua_CFunction)(lua_State *L);
extern void lua_pushstring(lua_State *L, const char *s);
extern void lua_createtable(lua_State *L, int narr, int nrec);
extern void lua_setfield(lua_State *L, int idx, const char *k);
extern void lua_pushcclosure(lua_State *L, lua_CFunction fn, int n);
static int greet(lua_State *L) { lua_pushstring(L, "hello"); return 1; }
int luaopen_greet(lua_State *L) {
	lua_createtable(L, 0, 1);
	lua_pushcclosure(L, greet, 0);
	lua_setfield(L, -2, "greet");
	return 1;
}
]])
		fs.write(path.join(rockDir, "greet-1.0.0-1.rockspec"), [[
			package = "greet"
			version = "1.0.0-1"
			source = { url = "git://example.com/greet" }
			build = {
				type = "builtin",
				modules = { greet = { "src/greet.c" } }
			}
		]])

		local appDir = path.join(tmpBase, "array-sources-app")
		fs.mkdir(appDir)
		fs.mkdir(path.join(appDir, "src"))
		fs.write(path.join(appDir, "src", "init.lua"),
			'local m = require("greet"); assert(m.greet() == "hello")')
		fs.write(path.join(appDir, "lde.json"), json.encode({
			name = "array-sources-app",
			version = "0.1.0",
			dependencies = { greet = { path = "../array-sources-rock" } }
		}))

		local app = lde.Package.open(appDir)
		app:installDependencies()
		local ok, err = app:runFile()
		if not ok then print(err) end
		test.truthy(ok)
	end)

--
-- Regression: src.sources as a string (not a table) must not crash ipairs
--

test.it("rockspec: sources = 'file.c' (string) is accepted without crashing", function()
	local dir = path.join(tmpBase, "string-sources-rock")
	fs.mkdir(dir)
	fs.write(path.join(dir, "string-sources-1.0-1.rockspec"), [[
package = "string-sources"
version = "1.0-1"
source = { url = "https://example.com" }
build = {
  type = "builtin",
  modules = {
    foo = { sources = "src/foo.c" },
  }
}
]])
	-- openRockspec must not error even though sources is a string
	local pkg, err = lde.Package.openRockspec(dir)
	test.truthy(pkg, err)
end)

--
-- Regression: build.install.lua files must be copied to target
--

test.it("rockspec: install.lua files are copied to target modulesDir", function()
	local dir = path.join(tmpBase, "install-lua-rock")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "lua"))
	fs.mkdir(path.join(dir, "lua", "mypkg"))
	fs.write(path.join(dir, "lua", "mypkg", "util.lua"), 'return "util"')
	fs.write(path.join(dir, "install-lua-1.0-1.rockspec"), [[
package = "install-lua"
version = "1.0-1"
source = { url = "https://example.com" }
build = {
  type = "builtin",
  modules = {},
  install = {
    lua = {
      ["mypkg.util"] = "lua/mypkg/util.lua",
    }
  }
}
]])

	local pkg, err = lde.Package.openRockspec(dir)
	test.truthy(pkg, err)

	local outputDir = path.join(dir, "target", "install-lua")
	local ok, berr = pkg:runBuildScript(outputDir)
	test.truthy(ok, berr)

	-- mypkg.util -> lua/mypkg/util.lua => target/mypkg/util.lua
	test.truthy(fs.exists(path.join(dir, "target", "mypkg", "util.lua")))
end)

--
-- Regression: array-style install.bin should use basename, not full relative path
--

test.it("rockspec: array-style install.bin uses basename as bin name and target location", function()
	local dir = path.join(tmpBase, "array-bin-rock")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "bin"))
	fs.write(path.join(dir, "bin", "myscript"), 'print("hi")')
	fs.write(path.join(dir, "array-bin-1.0-1.rockspec"), [[
package = "array-bin"
version = "1.0-1"
source = { url = "https://example.com" }
build = {
  type = "builtin",
  modules = {},
  install = {
    bin = { "bin/myscript" }
  }
}
]])

	local pkg, err = lde.Package.openRockspec(dir)
	test.truthy(pkg, err)

	local outputDir = path.join(dir, "target", "array-bin")
	local ok, berr = pkg:runBuildScript(outputDir)
	test.truthy(ok, berr)

	-- file must land at target/array-bin/myscript, not target/array-bin/bin/myscript
	test.truthy(fs.exists(path.join(outputDir, "myscript")))
	test.equal(fs.exists(path.join(outputDir, "bin", "myscript")), false)

	-- readConfig must return bin = "myscript", not "bin/myscript"
	local cfg = pkg:readConfig()
	test.equal(cfg.bin, "myscript")
end)

--
-- Regression: platform build.install.lua must merge over the base build, and
-- array-style lua entries install under their basename (LuaSec pattern).
--

test.it("rockspec: platform install.lua merges and array keys use basename", function()
	local platKey = jit.os == "OSX" and "macosx" or jit.os == "Windows" and "win32" or "linux"

	local dir = path.join(tmpBase, "plat-install-lua-rock")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "ssl.lua"), 'return "ssl"')
	fs.write(path.join(dir, "src", "https.lua"), 'return "https"')
	fs.write(path.join(dir, "plat-install-1.0-1.rockspec"), string.format([[
package = "plat-install"
version = "1.0-1"
source = { url = "https://example.com" }
build = {
  type = "builtin",
  modules = {},
  platforms = {
    ["%s"] = {
      install = {
        lua = {
          "src/ssl.lua",
          ["ssl.https"] = "src/https.lua",
        }
      }
    }
  }
}
]], platKey))

	local pkg, err = lde.Package.openRockspec(dir)
	test.truthy(pkg, err)

	local outputDir = path.join(dir, "target", "plat-install")
	local ok, berr = pkg:runBuildScript(outputDir)
	test.truthy(ok, berr)

	-- array key "src/ssl.lua" must land as target/ssl.lua (basename),
	-- not target/src/ssl.lua
	test.truthy(fs.exists(path.join(dir, "target", "ssl.lua")))
	test.equal(fs.exists(path.join(dir, "target", "src", "ssl.lua")), false)
	-- string key ssl.https -> target/ssl/https.lua
	test.truthy(fs.exists(path.join(dir, "target", "ssl", "https.lua")))
end)

--
-- Regression: rockspec native modules must honor incdirs (LuaSec bundles its
-- luasocket headers under src/luasocket and includes <luasocket/io.h>).
--

test.it("rockspec: native compile honors module incdirs", function()
	local dir = path.join(tmpBase, "incdirs-rock")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.mkdir(path.join(dir, "src", "inc"))
	fs.write(path.join(dir, "src", "inc", "greet.h"), "int lde_incdir_ok(void);\n")
	fs.write(path.join(dir, "src", "greet.c"), [[
#include <greet.h>
#include <stddef.h>
typedef struct lua_State lua_State;
typedef int (*lua_CFunction)(lua_State *L);
extern void lua_pushinteger(lua_State *L, int n);
int lde_incdir_ok(void) { return 42; }
static int greet(lua_State *L) { lua_pushinteger(L, lde_incdir_ok()); return 1; }
int luaopen_greet(lua_State *L) { return 0; }
]])
	fs.write(path.join(dir, "incdirs-1.0-1.rockspec"), [[
package = "incdirs"
version = "1.0-1"
source = { url = "https://example.com" }
build = {
  type = "builtin",
  modules = {
    greet = {
      sources = { "src/greet.c" },
      incdirs = { "src/inc" },
    }
  }
}
]])

	local pkg, err = lde.Package.openRockspec(dir)
	test.truthy(pkg, err)

	local outputDir = path.join(dir, "target", "incdirs")
	local ok, berr = pkg:runBuildScript(outputDir)
	-- Without incdirs support this fails: greet.h not found
	test.truthy(ok, berr)
	test.truthy(fs.exists(path.join(dir, "target", "greet.so")))
end)

--
-- Regression: a string-valued `libraries` (and string sources/libdirs/defines)
-- must be treated as a one-element list (lzlib declares `libraries = "z"` and
-- `libdirs = "$(ZLIB_LIBDIR)"`; without this the link drops -lz and the .so
-- fails with "undefined symbol: inflate").
--

test.it("rockspec: string-valued libraries/incdirs are normalized to lists", function()
	local dir = path.join(tmpBase, "strlibs-rock")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	-- zlib is always present on unix; libz.so.1 exports inflate()
	fs.write(path.join(dir, "src", "ztest.c"), [[
#include <zlib.h>
#include <stddef.h>
typedef struct lua_State lua_State;
typedef int (*lua_CFunction)(lua_State *L);
static int ztest(lua_State *L) { return 0; }
int luaopen_ztest(lua_State *L) {
  return (zlibVersion() != 0) ? 0 : 1;
}
]])
	fs.write(path.join(dir, "strlibs-1.0-1.rockspec"), [[
package = "strlibs"
version = "1.0-1"
source = { url = "https://example.com" }
build = {
  type = "builtin",
  modules = {
    ztest = {
      sources = "src/ztest.c",
      incdirs = "$(LUA_INCDIR)",
      libraries = "z",
    }
  }
}
]])

	local pkg, err = lde.Package.openRockspec(dir)
	test.truthy(pkg, err)

	local outputDir = path.join(dir, "target", "strlibs")
	local ok, berr = pkg:runBuildScript(outputDir)
	test.truthy(ok, berr)

	-- Without string->list normalization the link drops -lz and the .so has no
	-- NEEDED entry for libz (lzlib fails at require with "undefined symbol:
	-- inflate"). ldd lists libz only when -lz was actually passed.
	local so = path.join(dir, "target", "ztest.so")
	test.truthy(fs.exists(so))
	local code, lddOut = process.exec("ldd", { so }, { stdout = "pipe", stderr = "null" })
	test.truthy(code == 0 and lddOut and lddOut:find("libz", 1, true) ~= nil, lddOut or "ldd failed")
end)

--
-- Regression: make build.variables / install_variables substitution + bin promotion
--

--
-- lde-build exposed to build scripts via preload
--

test.it("build script can require('lde-build') and uses correct outDir", function()
	local dir = path.join(tmpBase, "ldebuild-exposed")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), 'return true')
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "ldebuild-exposed",
		version = "0.1.0",
		dependencies = {}
	}))

	-- build.lua that uses lde-build to write a file
	fs.write(path.join(dir, "build.lua"), [[
local build = require("lde-build")
build:write("output.txt", "hello from lde-build")
]])

	local pkg = lde.Package.open(dir)
	local outputDir = path.join(dir, "target", pkg:getName())
	local ok, err = pkg:runBuildScript(outputDir)
	test.truthy(ok, err)

	local writtenPath = path.join(outputDir, "output.txt")
	test.truthy(fs.exists(writtenPath))
	test.equal(fs.read(writtenPath), "hello from lde-build")
end)

test.it("build script lde-build instance has correct outDir matching LDE_OUTPUT_DIR", function()
	local dir = path.join(tmpBase, "ldebuild-outdir")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), 'return true')
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "ldebuild-outdir",
		version = "0.1.0",
		dependencies = {}
	}))

	-- build.lua that checks outDir matches LDE_OUTPUT_DIR
	fs.write(path.join(dir, "build.lua"), [[
local build = require("lde-build")
local outputDir = os.getenv("LDE_OUTPUT_DIR")
assert(build.outDir == outputDir,
"outDir mismatch: got " .. tostring(build.outDir) .. " expected " .. tostring(outputDir))
]])

	local pkg = lde.Package.open(dir)
	local outputDir = path.join(dir, "target", pkg:getName())
	local ok, err = pkg:runBuildScript(outputDir)
	test.truthy(ok, err)
end)

test.it("build script lde-build fetch, write, sh, and read methods work", function()
	local dir = path.join(tmpBase, "ldebuild-methods")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), 'return true')
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "ldebuild-methods",
		version = "0.1.0",
		dependencies = {}
	}))

	-- build.lua that exercises fetch, write, sh, and read
	fs.write(path.join(dir, "build.lua"), [[
local build = require("lde-build")

-- write and read
build:write("hello.txt", "world")
local content = build:read("hello.txt")
assert(content == "world", "read/write mismatch: " .. content)

-- sh should work (echo is available everywhere)
build:sh("echo hello > " .. build.outDir .. "/shell.txt")
local shellContent = build:read("shell.txt")
assert(shellContent:match("hello"), "sh/read mismatch: " .. shellContent)
]])

	local pkg = lde.Package.open(dir)
	local outputDir = path.join(dir, "target", pkg:getName())
	local ok, err = pkg:runBuildScript(outputDir)
	test.truthy(ok, err)

	-- Verify end result
	test.equal(fs.read(path.join(outputDir, "hello.txt")), "world")
	test.truthy(fs.read(path.join(outputDir, "shell.txt")):match("hello"))
end)

test.it("rockspec: make build.variables are substituted and passed to make", function()
	local dir = path.join(tmpBase, "make-vars-rock")
	fs.mkdir(dir)
	-- Makefile that writes MY_INCDIR to built.txt on build, then copies it on install.
	-- install must NOT depend on build (a phony dep would re-run build with install's vars,
	-- overwriting built.txt with an empty MY_INCDIR since it only appears in build.variables).
	fs.write(path.join(dir, "Makefile"), [[
build:
	echo "$(MY_INCDIR)" > built.txt

install:
	mkdir -p $(MY_LIBDIR)
	cp built.txt $(MY_LIBDIR)/vars.txt
	mkdir -p $(PREFIX)/bin
	echo "#!/bin/sh" > $(PREFIX)/bin/myprog
	chmod 755 $(PREFIX)/bin/myprog
]])
	fs.write(path.join(dir, "make-vars-1.0-1.rockspec"), [[
package = "make-vars"
version = "1.0-1"
source = { url = "https://example.com" }
build = {
  type = "make",
  variables     = { MY_INCDIR = "$(LUA_INCDIR)" },
  install_variables = { MY_LIBDIR = "$(LUADIR)", PREFIX = "$(PREFIX)" },
}
]])

	local pkg, err = lde.Package.openRockspec(dir)
	test.truthy(pkg, err)

	local outputDir = path.join(dir, "target", "make-vars")
	local ok, berr = pkg:runBuildScript(outputDir)
	test.truthy(ok, berr)

	-- vars.txt must exist in modulesDir (= target/)
	local modulesDir = path.join(dir, "target")
	test.truthy(fs.exists(path.join(modulesDir, "vars.txt")))

	-- vars.txt must contain the LuaJIT include path (substituted from $(LUA_INCDIR))
	local content = fs.read(path.join(modulesDir, "vars.txt")) or ""
	test.truthy(content:find("luajit", 1, true) or content:find("include", 1, true))

	-- myprog binary must be promoted from target/bin/ into target/make-vars/
	test.truthy(fs.exists(path.join(outputDir, "myprog")))

	-- readConfig must discover the promoted bin
	local cfg = pkg:readConfig()
	test.equal(cfg.bin, "myprog")
end)
