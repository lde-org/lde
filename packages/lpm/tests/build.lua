local test = require("lpm-test")

local Package = require("lpm-core.package")

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
		dependencies = {},
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
		["init.lua"] = 'return "hello"',
	})

	local pkg = Package.open(dir)
	pkg:build()

	local targetDir = pkg:getTargetDir()
	test.equal(fs.exists(targetDir), true)
end)

test.it("Package:build target contains the source files", function()
	local dir = makePackageWithSrc("build-contents", {
		["init.lua"] = 'return { version = "1.0" }',
		["helper.lua"] = 'return {}',
	})

	local pkg = Package.open(dir)
	pkg:build()

	local targetDir = pkg:getTargetDir()
	test.equal(fs.exists(path.join(targetDir, "init.lua")), true)
	test.equal(fs.exists(path.join(targetDir, "helper.lua")), true)
end)

test.it("Package:build is idempotent (can be called twice)", function()
	local dir = makePackageWithSrc("build-idempotent", {
		["init.lua"] = 'return true',
	})

	local pkg = Package.open(dir)
	pkg:build()
	pkg:build()

	test.equal(fs.exists(pkg:getTargetDir()), true)
end)

--
-- Package:installDependencies with path dependencies
--

test.it("installDependencies installs a local path dependency", function()
	local depDir = makePackageWithSrc("install-dep", {
		["init.lua"] = 'return { name = "install-dep" }',
	})

	local mainDir = path.join(tmpBase, "install-main")
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')

	fs.write(path.join(mainDir, "lpm.json"), json.encode({
		name = "install-main",
		version = "0.1.0",
		dependencies = {
			["install-dep"] = { path = "../install-dep" },
		},
	}))

	local pkg = Package.open(mainDir)
	pkg:installDependencies()

	local depInTarget = path.join(mainDir, "target", "install-dep")
	test.equal(fs.exists(depInTarget), true)
	test.equal(fs.exists(path.join(depInTarget, "init.lua")), true)
end)

test.it("installDependencies installs multiple dependencies", function()
	makePackageWithSrc("multi-dep-a", {
		["init.lua"] = 'return "a"',
	})

	makePackageWithSrc("multi-dep-b", {
		["init.lua"] = 'return "b"',
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
			["multi-dep-b"] = { path = "../multi-dep-b" },
		},
	}))

	local pkg = Package.open(mainDir)
	pkg:installDependencies()

	test.equal(fs.exists(path.join(mainDir, "target", "multi-dep-a", "init.lua")), true)
	test.equal(fs.exists(path.join(mainDir, "target", "multi-dep-b", "init.lua")), true)
end)

test.it("installDependencies skips already-installed symlink dependencies", function()
	makePackageWithSrc("skip-dep", {
		["init.lua"] = 'return "skip"',
	})

	local mainDir = path.join(tmpBase, "skip-main")
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')

	fs.write(path.join(mainDir, "lpm.json"), json.encode({
		name = "skip-main",
		version = "0.1.0",
		dependencies = {
			["skip-dep"] = { path = "../skip-dep" },
		},
	}))

	local pkg = Package.open(mainDir)
	pkg:installDependencies()
	pkg:installDependencies()

	test.equal(fs.exists(path.join(mainDir, "target", "skip-dep")), true)
end)

test.it("installDependencies re-runs build script on each call when output is a directory", function()
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
		version = "0.1.0",
	}))

	local mainDir = path.join(tmpBase, "rebuild-main")
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')
	fs.write(path.join(mainDir, "lpm.json"), json.encode({
		name = "rebuild-main",
		version = "0.1.0",
		dependencies = {
			["rebuild-sub"] = { path = "../rebuild-sub" },
		},
	}))

	local pkg = Package.open(mainDir)

	pkg:installDependencies()
	local content1 = fs.read(path.join(mainDir, "target", "rebuild-sub", "init.lua"))

	pkg:installDependencies()
	local content2 = fs.read(path.join(mainDir, "target", "rebuild-sub", "init.lua"))

	test.equal(content1, "return 1")
	test.equal(content2, "return 2")
end)

--
-- Transitive dependencies
--

test.it("installDependencies installs transitive dependencies", function()
	makePackageWithSrc("leaf-dep", {
		["init.lua"] = 'return "leaf"',
	})

	local midDir = path.join(tmpBase, "mid-dep")
	fs.mkdir(midDir)
	fs.mkdir(path.join(midDir, "src"))
	fs.write(path.join(midDir, "src", "init.lua"), 'return require("leaf-dep")')

	fs.write(path.join(midDir, "lpm.json"), json.encode({
		name = "mid-dep",
		version = "0.1.0",
		dependencies = {
			["leaf-dep"] = { path = "../leaf-dep" },
		},
	}))

	local rootDir = path.join(tmpBase, "trans-root")
	fs.mkdir(rootDir)
	fs.mkdir(path.join(rootDir, "src"))
	fs.write(path.join(rootDir, "src", "init.lua"), 'return true')

	fs.write(path.join(rootDir, "lpm.json"), json.encode({
		name = "trans-root",
		version = "0.1.0",
		dependencies = {
			["mid-dep"] = { path = "../mid-dep" },
		},
	}))

	local pkg = Package.open(rootDir)
	pkg:installDependencies()

	test.equal(fs.exists(path.join(rootDir, "target", "mid-dep")), true)
	test.equal(fs.exists(path.join(rootDir, "target", "leaf-dep")), true)
end)
