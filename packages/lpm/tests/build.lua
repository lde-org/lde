local test = require("lpm-test")

local lpm = require("lpm-core")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")

local tmpBase = path.join(env.tmpdir(), "lpm-build-tests")

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

	fs.write(path.join(dir, "lpm.json"), json.encode(config))

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

	local pkg = lpm.Package.open(dir)
	pkg:build()

	local targetDir = pkg:getTargetDir()
	test.truthy(fs.exists(targetDir))
end)

test.it("Package:build target contains the source files", function()
	local dir = makePackageWithSrc("build-contents", {
		["init.lua"] = 'return { version = "1.0" }',
		["helper.lua"] = 'return {}'
	})

	local pkg = lpm.Package.open(dir)
	pkg:build()

	local targetDir = pkg:getTargetDir()
	test.truthy(fs.exists(path.join(targetDir, "init.lua")))
	test.truthy(fs.exists(path.join(targetDir, "helper.lua")))
end)

test.it("Package:build is idempotent (can be called twice)", function()
	local dir = makePackageWithSrc("build-idempotent", {
		["init.lua"] = 'return true'
	})

	local pkg = lpm.Package.open(dir)
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

	fs.write(path.join(mainDir, "lpm.json"), json.encode({
		name = "install-main",
		version = "0.1.0",
		dependencies = {
			["install-dep"] = { path = "../install-dep" }
		}
	}))

	local pkg = lpm.Package.open(mainDir)
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

	fs.write(path.join(mainDir, "lpm.json"), json.encode({
		name = "multi-main",
		version = "0.1.0",
		dependencies = {
			["multi-dep-a"] = { path = "../multi-dep-a" },
			["multi-dep-b"] = { path = "../multi-dep-b" }
		}
	}))

	local pkg = lpm.Package.open(mainDir)
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

	fs.write(path.join(mainDir, "lpm.json"), json.encode({
		name = "skip-main",
		version = "0.1.0",
		dependencies = {
			["skip-dep"] = { path = "../skip-dep" }
		}
	}))

	local pkg = lpm.Package.open(mainDir)
	pkg:installDependencies()
	pkg:installDependencies()

	test.truthy(fs.exists(path.join(mainDir, "target", "skip-dep")))
end)

test.skip("installDependencies re-runs build script on each call when output is a directory", function()
	-- "rebuild-sub" has a build.lua that writes an incrementing counter to init.lua.
	-- The counter persists in a sibling file next to the output dir so it survives
	-- the fs.copy that happens before each build script run.
	local buildScript = [[
local outputDir = os.getenv("LPM_OUTPUT_DIR")
local counterFile = outputDir .. ".count"
local count = 0
local f = io.open(counterFile, "r")
if f then count = tonumber(f:read("*a")) or 0; f:close() end
count = count + 1
local h = io.open(counterFile, "wb"); h:write(tostring(count)); h:close()
local out = io.open(outputDir .. "/init.lua", "wb")
out:write(string.format("return %d", count))
out:close()
]]

	local subDir = path.join(tmpBase, "rebuild-sub")
	fs.mkdir(tmpBase)
	fs.mkdir(subDir)
	fs.mkdir(path.join(subDir, "src"))
	fs.write(path.join(subDir, "src", "init.lua"), 'return 0')
	fs.write(path.join(subDir, "build.lua"), buildScript)
	fs.write(path.join(subDir, "lpm.json"), json.encode({
		name = "rebuild-sub",
		version = "0.1.0"
	}))

	local mainDir = path.join(tmpBase, "rebuild-main")
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')
	fs.write(path.join(mainDir, "lpm.json"), json.encode({
		name = "rebuild-main",
		version = "0.1.0",
		dependencies = {
			["rebuild-sub"] = { path = "../rebuild-sub" }
		}
	}))

	local pkg = lpm.Package.open(mainDir)

	pkg:installDependencies()
	local content1 = fs.read(path.join(mainDir, "target", "rebuild-sub", "init.lua"))

	pkg:installDependencies()
	local content2 = fs.read(path.join(mainDir, "target", "rebuild-sub", "init.lua"))

	test.equal(content1, "return 1")
	test.equal(content2, "return 2")
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
	fs.write(path.join(mainDir, "lpm.json"), json.encode({
		name = "lockfile-main",
		version = "0.1.0",
		dependencies = {
			["lockfile-dep"] = { path = "../lockfile-dep" }
		}
	}))

	local pkg = lpm.Package.open(mainDir)
	pkg:installDependencies()

	local lockPath = path.join(mainDir, "lpm-lock.json")
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
	fs.write(path.join(mainDir, "lpm.json"), json.encode({
		name = "pinned-main",
		version = "0.1.0",
		dependencies = {
			["pinned-dep"] = { path = "../pinned-dep" }
		}
	}))

	local pkg = lpm.Package.open(mainDir)
	pkg:installDependencies()

	-- Manually overwrite the lockfile to point at other-dep instead
	lpm.Lockfile.new(path.join(mainDir, "lpm-lock.json"), {
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

	fs.write(path.join(midDir, "lpm.json"), json.encode({
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

	fs.write(path.join(rootDir, "lpm.json"), json.encode({
		name = "trans-root",
		version = "0.1.0",
		dependencies = {
			["mid-dep"] = { path = "../mid-dep" }
		}
	}))

	local pkg = lpm.Package.open(rootDir)
	pkg:installDependencies()

	test.truthy(fs.exists(path.join(rootDir, "target", "mid-dep")))
	test.truthy(fs.exists(path.join(rootDir, "target", "leaf-dep")))
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

	local pkg = lpm.Package.openRockspec(dir)
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

	local pkg = lpm.Package.openRockspec(dir)
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
	local plat = require("process").platform
	local platKey = plat == "darwin" and "macosx" or plat

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

	local pkg = lpm.Package.openRockspec(dir)
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
