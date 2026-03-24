local test = require("lpm-test")

local lpm = require("lpm-core")

local fs = require("fs")
local env = require("env")
local path = require("path")

local tmpBase = path.join(env.tmpdir(), "lpm-init-tests")

-- Clean up from any previous test run
fs.rmdir(tmpBase)

--
-- Package.init (initialize)
--

test.it("Package.init creates lpm.json in the target directory", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "new-project")
	fs.mkdir(dir)

	lpm.Package.init(dir)

	test.equal(fs.exists(path.join(dir, "lpm.json")), true)
end)

test.it("Package.init uses the directory basename as the package name", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "my-lib")
	fs.mkdir(dir)

	lpm.Package.init(dir)

	local pkg = lpm.Package.open(dir)
	test.equal(pkg:getName(), "my-lib")
end)

test.it("Package.init sets version to 0.1.0", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "versioned")
	fs.mkdir(dir)

	lpm.Package.init(dir)

	local pkg = lpm.Package.open(dir)
	local config = pkg:readConfig()
	test.equal(config.version, "0.1.0")
end)

test.it("Package.init creates a src directory with init.lua", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "with-src")
	fs.mkdir(dir)

	lpm.Package.init(dir)

	test.equal(fs.exists(path.join(dir, "src")), true)
	test.equal(fs.isfile(path.join(dir, "src", "init.lua")), true)
end)

test.it("Package.init creates a .gitignore", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "with-gitignore")
	fs.mkdir(dir)

	lpm.Package.init(dir)

	test.equal(fs.exists(path.join(dir, ".gitignore")), true)

	local content = fs.read(path.join(dir, ".gitignore"))
	test.notEqual(content, nil)
	test.notEqual(string.find(content, "/target/", 1, true), nil)
end)

test.it("Package.init creates a .luarc.json", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "with-luarc")
	fs.mkdir(dir)

	lpm.Package.init(dir)

	test.equal(fs.isfile(path.join(dir, ".luarc.json")), true)
end)

test.it("Package.init errors if lpm.json already exists", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "already-exists")
	fs.mkdir(dir)
	fs.write(path.join(dir, "lpm.json"), '{"name":"existing","version":"1.0.0"}')

	local ok, err = pcall(lpm.Package.init, dir)
	test.equal(ok, false)
	test.notEqual(err, nil)
end)

test.it("Package.init result can be opened as a Package", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "openable")
	fs.mkdir(dir)

	local pkg = lpm.Package.init(dir)
	test.notEqual(pkg, nil)

	local reopened, err = lpm.Package.open(dir)
	test.notEqual(reopened, nil)
	test.equal(err, nil)
end)
