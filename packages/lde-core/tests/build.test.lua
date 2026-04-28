local test = require("lde-test")

local lde = require("lde-core")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")

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

test.skipIf(jit.os == "Windows" or jit.os == "OSX")(
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

test.skipIf(jit.os == "Windows")("rockspec: make build.variables are substituted and passed to make", function()
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
