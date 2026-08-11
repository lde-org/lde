local test = require("lde-test")

local lde = require("lde-core")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")
local process = require("process")
local Archive = require("archive")

local tmpBase = path.join(env.tmpdir(), "lde-package-tests")

-- Clean up from any previous test run
fs.rmdir(tmpBase)

--- Creates a minimal package directory with lde.json inside a test callback.
local function makePackageDir(name, config)
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, name)
	fs.mkdir(dir)

	config = config or {
		name = name,
		version = "0.1.0",
		dependencies = {}
	}

	fs.write(path.join(dir, "lde.json"), json.encode(config))
	return dir
end

--
-- Package.open
--

test.it("Package.open succeeds for a directory with lde.json", function()
	local dir = makePackageDir("valid-pkg")
	local pkg, err = lde.Package.open(dir)
	test.truthy(pkg)
	test.falsy(err)
end)

test.it("Package.open fails for a directory without lde.json", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "no-config")
	fs.mkdir(dir)

	local pkg, err = lde.Package.open(dir)
	test.falsy(pkg)
	test.truthy(err)
end)

test.it("Package.open fails for a nonexistent directory", function()
	local pkg, err = lde.Package.open(path.join(tmpBase, "does-not-exist"))
	test.falsy(pkg)
	test.truthy(err)
end)

test.skipIf(jit.os == "Windows")("Package.open fails gracefully when the cwd no longer exists", function()
	fs.mkdir(tmpBase)
	local parent = path.join(tmpBase, "ghost-cwd")
	local dir = path.join(parent, "sub")
	fs.mkdir(parent)
	fs.mkdir(dir)

	local oldCwd = env.cwd()
	test.truthy(env.chdir(dir))

	-- Delete the tree from a child process that has left it first: Linux
	-- refuses to rmdir a directory that is the cwd of the *calling* process,
	-- but a separate process (e.g. `rm -rf` from another shell) can delete it
	-- — which is exactly the real-world "deleted cwd" scenario.
	local ok, err = pcall(function()
		local code = process.exec("sh", { "-c", "cd / && rm -rf '" .. parent .. "'" }, {})
		test.equal(code, 0)

		-- Previously this crashed with "invalid value (nil) at index 1 in
		-- table for 'concat'" because env.cwd() returns nil once the cwd is
		-- gone and the nil leaked into path.join.
		local pkg, pkgErr = lde.Package.open()
		test.falsy(pkg)
		test.truthy(pkgErr)
		test.includes(pkgErr or "", "no longer exists")
	end)

	env.chdir(oldCwd)
	if not ok then error(err) end
end)

--
-- Package path helpers
--

test.it("Package:getDir returns the directory it was opened from", function()
	local dir = makePackageDir("dir-pkg")
	local pkg = lde.Package.open(dir)
	test.equal(pkg:getDir(), dir)
end)

test.it("Package:getName reads the name from lde.json", function()
	local dir = makePackageDir("named-pkg", {
		name = "my-cool-lib",
		version = "2.0.0",
		dependencies = {}
	})

	local pkg = lde.Package.open(dir)
	test.equal(pkg:getName(), "my-cool-lib")
end)

test.it("Package:getSrcDir returns <dir>/src", function()
	local dir = makePackageDir("src-pkg")
	local pkg = lde.Package.open(dir)
	test.equal(pkg:getSrcDir(), path.join(dir, "src"))
end)

test.it("Package:getTestDir returns <dir>/tests", function()
	local dir = makePackageDir("test-pkg")
	local pkg = lde.Package.open(dir)
	test.equal(pkg:getTestDir(), path.join(dir, "tests"))
end)

test.it("Package:getModulesDir returns <dir>/target", function()
	local dir = makePackageDir("mod-pkg")
	local pkg = lde.Package.open(dir)
	test.equal(pkg:getModulesDir(), path.join(dir, "target"))
end)

test.it("Package:getTargetDir returns <dir>/target/<name>", function()
	local dir = makePackageDir("target-pkg", {
		name = "target-pkg",
		version = "0.1.0",
		dependencies = {}
	})

	local pkg = lde.Package.open(dir)
	test.equal(pkg:getTargetDir(), path.join(dir, "target", "target-pkg"))
end)

--
-- Package:readConfig
--

test.it("Package:readConfig returns the parsed config", function()
	local dir = makePackageDir("read-cfg", {
		name = "read-cfg",
		version = "3.5.0",
		dependencies = {
			dep1 = { path = "../dep1" }
		}
	})

	local pkg = lde.Package.open(dir)
	local config = pkg:readConfig()
	test.equal(config.name, "read-cfg")
	test.equal(config.version, "3.5.0")
	test.equal(config.dependencies.dep1.path, "../dep1")
end)

test.it("Package:readConfig caches and returns the same object", function()
	local dir = makePackageDir("cache-cfg")
	local pkg = lde.Package.open(dir)

	local c1 = pkg:readConfig()
	local c2 = pkg:readConfig()
	test.equal(c1, c2)
end)

--
-- Package:getDependencies / getDevDependencies
--

test.it("Package:getDependencies returns dependencies from config", function()
	local dir = makePackageDir("deps-pkg", {
		name = "deps-pkg",
		version = "0.1.0",
		dependencies = {
			a = { path = "../a" },
			b = { path = "../b" }
		}
	})

	local pkg = lde.Package.open(dir)
	local deps = pkg:getDependencies()
	test.equal(deps.a.path, "../a")
	test.equal(deps.b.path, "../b")
end)

test.it("Package:getDependencies returns empty table when none defined", function()
	local dir = makePackageDir("no-deps")
	local pkg = lde.Package.open(dir)
	local deps = pkg:getDependencies()
	test.equal(test.count(deps), 0)
end)

test.it("Package:getDevDependencies returns devDependencies from config", function()
	local dir = makePackageDir("devdeps-pkg", {
		name = "devdeps-pkg",
		version = "0.1.0",
		dependencies = {},
		devDependencies = {
			testutil = { path = "../testutil" }
		}
	})

	local pkg = lde.Package.open(dir)
	local devDeps = pkg:getDevDependencies()
	test.equal(devDeps.testutil.path, "../testutil")
end)

--
-- Package:__tostring
--

test.it("Package tostring includes the directory", function()
	local dir = makePackageDir("str-pkg")
	local pkg = lde.Package.open(dir)
	local s = tostring(pkg)
	test.equal(s, "Package(" .. dir .. ")")
end)

--
-- Rockspec dependency
--

test.it("rockspec dep: can require(packagename) from a consumer package", function()
	fs.mkdir(tmpBase)

	-- Create a fake rockspec package with files scattered in odd locations
	local rockDir = path.join(tmpBase, "rock-dep")
	fs.mkdir(rockDir)
	fs.mkdir(path.join(rockDir, "src"))
	fs.mkdir(path.join(rockDir, "src", "internal"))
	fs.write(path.join(rockDir, "src", "core.lua"), 'return { value = 42 }')
	fs.write(path.join(rockDir, "src", "internal", "util.lua"), 'return {}')
	fs.write(path.join(rockDir, "rock-dep-1.0.0-1.rockspec"), [[
		package = "rock-dep"
		version = "1.0.0-1"
		source = { url = "git://example.com/rock-dep" }
		build = {
			type = "builtin",
			modules = {
				["rock-dep"] = "src/core.lua",
				["rock-dep.util"] = "src/internal/util.lua",
			}
		}
	]])

	-- Consumer lde package that depends on the rockspec package via path
	local appDir = path.join(tmpBase, "rock-consumer")
	fs.mkdir(appDir)
	fs.mkdir(path.join(appDir, "src"))
	fs.write(path.join(appDir, "src", "init.lua"), [[
		local dep = require("rock-dep")
		assert(dep.value == 42, "expected value 42, got " .. tostring(dep.value))
	]])
	fs.write(path.join(appDir, "lde.json"), json.encode({
		name = "rock-consumer",
		version = "0.1.0",
		dependencies = {
			["rock-dep"] = { path = "../rock-dep" }
		}
	}))

	local app = lde.Package.open(appDir)
	app:installDependencies()
	app:build()

	-- buildfn should have copied modules to target/ at their require-able paths
	test.truthy(fs.exists(path.join(appDir, "target", "rock-dep.lua")))
	test.truthy(fs.exists(path.join(appDir, "target", "rock-dep", "util.lua")))

	local ok, err = app:runFile()
	if not ok then print(err) end
	test.truthy(ok)
end)

test.it(
	"rockspec native C module: can require and call a C function returning 52", function()
		fs.mkdir(tmpBase)

		local rockDir = path.join(tmpBase, "native-rock")
		fs.mkdir(rockDir)
		fs.mkdir(path.join(rockDir, "csrc"))

		-- Minimal C module using raw Lua ABI, no headers needed
		fs.write(path.join(rockDir, "csrc", "answer.c"), [[
#include <stddef.h>

typedef struct lua_State lua_State;
typedef int (*lua_CFunction)(lua_State *L);

extern void lua_pushinteger(lua_State *L, ptrdiff_t n);
extern void lua_createtable(lua_State *L, int narr, int nrec);
extern void lua_setfield(lua_State *L, int idx, const char *k);
extern void lua_pushcclosure(lua_State *L, lua_CFunction fn, int n);

static int answer(lua_State *L) {
	lua_pushinteger(L, 52);
	return 1;
}

int luaopen_answer(lua_State *L) {
	lua_createtable(L, 0, 1);
	lua_pushcclosure(L, answer, 0);
	lua_setfield(L, -2, "answer");
	return 1;
}
]])

		fs.write(path.join(rockDir, "native-rock-1.0.0-1.rockspec"), [[
		package = "native-rock"
		version = "1.0.0-1"
		source = { url = "git://example.com/native-rock" }
		build = {
			type = "builtin",
			modules = {
				answer = "csrc/answer.c",
			}
		}
	]])

		local appDir = path.join(tmpBase, "native-consumer")
		fs.mkdir(appDir)
		fs.mkdir(path.join(appDir, "src"))
		fs.write(path.join(appDir, "src", "init.lua"), [[
		local m = require("answer")
		assert(m.answer() == 52, "expected 52, got " .. tostring(m.answer()))
	]])
		fs.write(path.join(appDir, "lde.json"), json.encode({
			name = "native-consumer",
			version = "0.1.0",
			dependencies = {
				["native-rock"] = { path = "../native-rock" }
			}
		}))

		local app = lde.Package.open(appDir)
		app:installDependencies()
		app:build()

		test.truthy(fs.exists(path.join(appDir, "target", "answer" .. (jit.os == "Windows" and ".dll" or ".so"))))

		local ok, err = app:runFile()
		if not ok then print(err) end
		test.truthy(ok)
	end)

test.it("bundle includes top-level lua files in target/ (not just subdir modules)", function()
	local dir = makePackageDir("bundle-toplevel", { name = "bundle-toplevel", version = "0.1.0", dependencies = {} })
	local targetDir = path.join(dir, "target")
	fs.mkdir(targetDir)

	-- top-level module (e.g. socket.lua installed by luasocket)
	fs.write(path.join(targetDir, "mymod.lua"), "return 42")
	-- subdir module
	fs.mkdir(path.join(targetDir, "mymod"))
	fs.write(path.join(targetDir, "mymod", "sub.lua"), "return 99")

	local pkg = lde.Package.open(dir)
	local bundle = pkg:bundle()

	test.truthy(bundle:find('"mymod"'), "top-level mymod.lua should be bundled as 'mymod'")
	test.truthy(bundle:find('"mymod.sub"'), "subdir mymod/sub.lua should be bundled as 'mymod.sub'")
end)

test.it("bundle excludes test files (target/tests and *.test.lua)", function()
	local dir = makePackageDir("bundle-notests", { name = "bundle-notests", version = "0.1.0", dependencies = {} })
	local targetDir = path.join(dir, "target")
	fs.mkdir(targetDir)

	-- target/tests: the artifact lde test creates to expose the package's tests/ dir
	fs.mkdir(path.join(targetDir, "tests"))
	fs.write(path.join(targetDir, "tests", "main.test.lua"), "return 1")
	-- test helper modules (tests/lib/...) must not ship either
	fs.mkdir(path.join(targetDir, "tests", "lib"))
	fs.write(path.join(targetDir, "tests", "lib", "helpers.lua"), "return 2")

	-- a stray *.test.lua inside an otherwise normal module dir
	fs.mkdir(path.join(targetDir, "mymod"))
	fs.write(path.join(targetDir, "mymod", "sub.test.lua"), "return 3")
	-- ... while its non-test sibling is real code and must still ship
	fs.write(path.join(targetDir, "mymod", "sub.lua"), "return 99")

	local pkg = lde.Package.open(dir)
	local bundle = pkg:bundle()
	---@cast bundle string

	test.falsy(bundle:find('"tests.main.test"'), "tests/main.test.lua must not be bundled")
	test.falsy(bundle:find('"tests.lib.helpers"'), "tests/lib/helpers.lua must not be bundled")
	test.falsy(bundle:find('"mymod.sub.test"'), "*.test.lua files must not be bundled")
	test.truthy(bundle:find('"mymod.sub"'), "non-test sibling modules must still be bundled")
end)

--
-- getDependencyPath
--

test.it("getDependencyPath returns nil for git dep without a commit", function()
	local dir = makePackageDir("nodep-commit", { name = "nodep-commit", version = "0.1.0", dependencies = {} })
	local pkg = lde.Package.open(dir)

	local depPath, err = pkg:getDependencyPath("foo", { git = "https://example.com/foo.git" })
	test.falsy(depPath)
	test.includes(err, "no commit pinned")
end)

test.it("getDependencyPath returns path for git dep with commit", function()
	local dir = makePackageDir("with-commit", { name = "with-commit", version = "0.1.0", dependencies = {} })
	local pkg = lde.Package.open(dir)

	local depPath, err = pkg:getDependencyPath("foo", { git = "https://example.com/foo.git", commit = "abc123" })
	test.truthy(depPath)
	test.falsy(err)
	test.truthy(depPath:find("foo"))
	test.truthy(depPath:find("abc123"))
end)

--
-- .src.rock materialization (cerulean regression)
--

--- Build a fake extracted .src.rock cache dir: a rockspec, the original source
--- archive, and a stray leftover `<name>/` dir like a buggy install would leave.
test.it("materializeSrcRock prefers the nested archive over a leftover package dir", function()
	local base = path.join(tmpBase, "srcrock-nested")
	fs.rmdir(base)
	fs.mkdir(base)

	fs.write(path.join(base, "ceru-1.0-1.rockspec"), [[
rockspec_format = "3.0"
package = "ceru"
version = "1.0-1"
source = { url = "https://example.com/ceru-1.0.tar.gz" }
build = {
  type = "builtin",
  modules = { ceru = "src/init.lua" },
  install = { bin = { ceru = "bin/ceru" } },
}
]])

	-- The nested archive holds the real source tree (stripComponents=true drops
	-- the ceru-1.0/ top-level dir on extraction).
	local arch = Archive.new({
		["ceru-1.0/src/init.lua"] = "return require('ceru.cli').run()",
		["ceru-1.0/bin/ceru"] = "#!/usr/bin/env lua\nrequire('ceru')\n",
	})
	local ok, err = arch:save(path.join(base, "ceru-1.0.tar.gz"))
	test.truthy(ok, err or "failed to write nested archive")

	-- The stray dir a broken install left behind: a stale stamp and no sources.
	fs.mkdirAll(path.join(base, "ceru", "target", "ceru"))
	fs.write(path.join(base, "ceru", "target", "ceru", ".lde-built"), "stale")

	local srcDir, rockspecPath, merr = lde.util.materializeSrcRock(base)
	test.truthy(srcDir, merr or "materializeSrcRock failed")
	test.falsy(merr)
	test.equal(rockspecPath, path.join(base, "ceru-1.0-1.rockspec"))
	-- The nested archive is extracted and wins over the leftover dir.
	test.equal(srcDir, path.join(base, "ceru-1.0"))
	test.truthy(fs.isfile(path.join(srcDir, "src", "init.lua")))
	test.truthy(fs.isfile(path.join(srcDir, "bin", "ceru")))

	-- openSrcRock opens a real package from it, and the build materializes the
	-- custom bin name (cerulean's rockspec installs bin "ceru").
	local pkg, perr = lde.util.openSrcRock(base, "https://luarocks.org/ceru-1.0-1.src.rock")
	test.truthy(pkg, perr or "openSrcRock failed")
	test.equal(pkg:getName(), "ceru")
	local config = pkg:readConfig()
	test.equal(config.bin, "ceru")

	local built, derr = pkg:build()
	test.truthy(built, derr or "build failed")
	test.truthy(fs.isfile(path.join(srcDir, "target", "ceru", "ceru")))
	test.truthy(fs.isfile(path.join(srcDir, "target", "ceru", "init.lua")))
end)
