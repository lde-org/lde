local test = require("lde-test")

local lde = require("lde-core")

local fs = require("fs")
local env = require("env")
local path = require("path")

local tmpBase = path.join(env.tmpdir(), "lpm-init-tests")

-- Clean up from any previous test run
fs.rmdir(tmpBase)

--
-- Package.init (initialize)
--

test.it("Package.init creates lde.json in the target directory", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "new-project")
	fs.mkdir(dir)

	lde.Package.init(dir)

	test.truthy(fs.exists(path.join(dir, "lde.json")))
end)

test.it("Package.init uses the directory basename as the package name", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "my-lib")
	fs.mkdir(dir)

	lde.Package.init(dir)

	local pkg = lde.Package.open(dir)
	test.equal(pkg:getName(), "my-lib")
end)

test.it("Package.init sets version to 0.1.0", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "versioned")
	fs.mkdir(dir)

	lde.Package.init(dir)

	local pkg = lde.Package.open(dir)
	local config = pkg:readConfig()
	test.equal(config.version, "0.1.0")
end)

test.it("Package.init creates a src directory with init.lua", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "with-src")
	fs.mkdir(dir)

	lde.Package.init(dir)

	test.truthy(fs.exists(path.join(dir, "src")))
	test.truthy(fs.isfile(path.join(dir, "src", "init.lua")))
end)

test.it("Package.init creates a .gitignore", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "with-gitignore")
	fs.mkdir(dir)

	lde.Package.init(dir)

	test.truthy(fs.exists(path.join(dir, ".gitignore")))

	local content = fs.read(path.join(dir, ".gitignore"))
	test.truthy(content)
	test.includes(content, "/target/")
end)

test.it("Package.init creates a .luarc.json", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "with-luarc")
	fs.mkdir(dir)

	lde.Package.init(dir)

	test.truthy(fs.isfile(path.join(dir, ".luarc.json")))
end)

test.it("Package.init errors if lde.json already exists", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "already-exists")
	fs.mkdir(dir)
	fs.write(path.join(dir, "lde.json"), '{"name":"existing","version":"1.0.0"}')

	local ok, err = pcall(lde.Package.init, dir)
	test.falsy(ok)
	test.truthy(err)
end)

test.it("Package.init result can be opened as a Package", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "openable")
	fs.mkdir(dir)

	local pkg = lde.Package.init(dir)
	test.truthy(pkg)

	local reopened, err = lde.Package.open(dir)
	test.truthy(reopened)
	test.falsy(err)
end)
