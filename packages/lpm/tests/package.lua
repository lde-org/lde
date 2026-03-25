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
