-- NOTE: These tests require network access — they clone from GitHub.
local test = require("lde-test")

local lde = require("lde-core")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")

local tmpBase = path.join(env.tmpdir(), "lde-git-tests")

-- Clean up from any previous test run
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

--
-- Git dependency installation
--

test.it("rockspec git dep: middleclass can be required after install", function()
	local dir = path.join(tmpBase, "middleclass-consumer")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), [[
		local class = require("middleclass")
		local Animal = class("Animal")
		function Animal:initialize(name) self.name = name end
		local a = Animal("cat")
		assert(a.name == "cat", "expected name 'cat', got " .. tostring(a.name))
	]])
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "middleclass-consumer",
		version = "0.1.0",
		dependencies = {
			middleclass = {
				git = "https://github.com/kikito/middleclass",
				branch = "master",
				rockspec = "rockspecs/middleclass-4.1.1-0.rockspec"
			}
		}
	}))

	local pkg = lde.Package.open(dir)
	pkg:installDependencies()
	pkg:build()

	test.truthy(fs.exists(path.join(dir, "target", "middleclass.lua")))

	local ok, err = pkg:runFile()
	if not ok then print(err) end
	test.truthy(ok)
end)

test.it("rockspec git dep: luafilesystem native C module works", function()
	local dir = path.join(tmpBase, "lfs-consumer")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), [[
		local lfs = require("lfs")
		local attr = lfs.attributes(".")
		assert(attr ~= nil, "lfs.attributes returned nil")
		assert(attr.mode == "directory", "expected directory, got " .. tostring(attr.mode))
	]])
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "lfs-consumer",
		version = "0.1.0",
		dependencies = {
			luafilesystem = {
				git = "https://github.com/lunarmodules/luafilesystem",
				branch = "master"
			}
		}
	}))

	local pkg = lde.Package.open(dir)
	pkg:installDependencies()
	pkg:build()

	local lockfile = pkg:readLockfile()
	test.truthy(lockfile)
	local entry = lockfile:getDependency("luafilesystem")
	test.truthy(entry)
	test.match(entry, { git = "https://github.com/lunarmodules/luafilesystem" })
	test.truthy(entry.commit)
	test.truthy(entry.commit:match("^%x+$"))

	local ok, err = pkg:runFile()
	if not ok then print(err) end
	test.truthy(ok)
end)
