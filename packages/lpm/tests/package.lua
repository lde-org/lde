local test = require("lpm-test")

local lpm = require("lpm-core")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")

local tmpBase = path.join(env.tmpdir(), "lpm-package-tests")

--- Creates a minimal package directory with lpm.json inside a test callback.
local function makePackageDir(name, config)
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, name)
	fs.mkdir(dir)

	config = config or {
		name = name,
		version = "0.1.0",
		dependencies = {}
	}

	fs.write(path.join(dir, "lpm.json"), json.encode(config))
	return dir
end

--
-- Package.open
--

test.it("Package.open succeeds for a directory with lpm.json", function()
	local dir = makePackageDir("valid-pkg")
	local pkg, err = lpm.Package.open(dir)
	test.truthy(pkg)
	test.falsy(err)
end)

test.it("Package.open fails for a directory without lpm.json", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "no-config")
	fs.mkdir(dir)

	local pkg, err = lpm.Package.open(dir)
	test.falsy(pkg)
	test.truthy(err)
end)

test.it("Package.open fails for a nonexistent directory", function()
	local pkg, err = lpm.Package.open(path.join(tmpBase, "does-not-exist"))
	test.falsy(pkg)
	test.truthy(err)
end)

--
-- Package path helpers
--

test.it("Package:getDir returns the directory it was opened from", function()
	local dir = makePackageDir("dir-pkg")
	local pkg = lpm.Package.open(dir)
	test.equal(pkg:getDir(), dir)
end)

test.it("Package:getName reads the name from lpm.json", function()
	local dir = makePackageDir("named-pkg", {
		name = "my-cool-lib",
		version = "2.0.0",
		dependencies = {}
	})

	local pkg = lpm.Package.open(dir)
	test.equal(pkg:getName(), "my-cool-lib")
end)

test.it("Package:getSrcDir returns <dir>/src", function()
	local dir = makePackageDir("src-pkg")
	local pkg = lpm.Package.open(dir)
	test.equal(pkg:getSrcDir(), path.join(dir, "src"))
end)

test.it("Package:getTestDir returns <dir>/tests", function()
	local dir = makePackageDir("test-pkg")
	local pkg = lpm.Package.open(dir)
	test.equal(pkg:getTestDir(), path.join(dir, "tests"))
end)

test.it("Package:getModulesDir returns <dir>/target", function()
	local dir = makePackageDir("mod-pkg")
	local pkg = lpm.Package.open(dir)
	test.equal(pkg:getModulesDir(), path.join(dir, "target"))
end)

test.it("Package:getTargetDir returns <dir>/target/<name>", function()
	local dir = makePackageDir("target-pkg", {
		name = "target-pkg",
		version = "0.1.0",
		dependencies = {}
	})

	local pkg = lpm.Package.open(dir)
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

	local pkg = lpm.Package.open(dir)
	local config = pkg:readConfig()
	test.equal(config.name, "read-cfg")
	test.equal(config.version, "3.5.0")
	test.equal(config.dependencies.dep1.path, "../dep1")
end)

test.it("Package:readConfig caches and returns the same object", function()
	local dir = makePackageDir("cache-cfg")
	local pkg = lpm.Package.open(dir)

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

	local pkg = lpm.Package.open(dir)
	local deps = pkg:getDependencies()
	test.equal(deps.a.path, "../a")
	test.equal(deps.b.path, "../b")
end)

test.it("Package:getDependencies returns empty table when none defined", function()
	local dir = makePackageDir("no-deps")
	local pkg = lpm.Package.open(dir)
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

	local pkg = lpm.Package.open(dir)
	local devDeps = pkg:getDevDependencies()
	test.equal(devDeps.testutil.path, "../testutil")
end)

--
-- Package:__tostring
--

test.it("Package tostring includes the directory", function()
	local dir = makePackageDir("str-pkg")
	local pkg = lpm.Package.open(dir)
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

	-- Consumer lpm package that depends on the rockspec package via path
	local appDir = path.join(tmpBase, "rock-consumer")
	fs.mkdir(appDir)
	fs.mkdir(path.join(appDir, "src"))
	fs.write(path.join(appDir, "src", "init.lua"), [[
		local dep = require("rock-dep")
		assert(dep.value == 42, "expected value 42, got " .. tostring(dep.value))
	]])
	fs.write(path.join(appDir, "lpm.json"), json.encode({
		name = "rock-consumer",
		version = "0.1.0",
		dependencies = {
			["rock-dep"] = { path = "../rock-dep" }
		}
	}))

	local app = lpm.Package.open(appDir)
	app:installDependencies()
	app:build()

	-- buildfn should have copied modules to target/ at their require-able paths
	test.truthy(fs.exists(path.join(appDir, "target", "rock-dep.lua")))
	test.truthy(fs.exists(path.join(appDir, "target", "rock-dep", "util.lua")))
	-- init.lua should have been generated in the package target dir
	test.truthy(fs.exists(path.join(appDir, "target", "rock-dep", "init.lua")))

	local ok, err = app:runFile()
	if not ok then print(err) end
	test.truthy(ok)
end)

test.it("rockspec native C module: can require and call a C function returning 52", function()
	-- TODO: Re-enable on MacOS when nightly exports LuaJIT symbols.
	if jit.os == "Windows" or jit.os == "OSX" then return end
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
	fs.write(path.join(appDir, "lpm.json"), json.encode({
		name = "native-consumer",
		version = "0.1.0",
		dependencies = {
			["native-rock"] = { path = "../native-rock" }
		}
	}))

	local app = lpm.Package.open(appDir)
	app:installDependencies()
	app:build()

	test.truthy(fs.exists(path.join(appDir, "target", "answer.so")))

	local ok, err = app:runFile()
	if not ok then print(err) end
	test.truthy(ok)
end)
