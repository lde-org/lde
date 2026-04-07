local test = require("lde-test")
local lde = require("lde-core")
local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")
local process = require("process2")

local tmpBase = path.join(env.tmpdir(), "lde-commonrocks-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

local function makeApp(name, deps)
	local dir = path.join(tmpBase, name)
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), "return true")
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = name,
		version = "0.1.0",
		dependencies = deps
	}))
	return lde.Package.open(dir)
end

test.skipIf(jit.os == "Windows" or jit.os == "OSX")("luarocks: lpeg matches a pattern", function()
	local app = makeApp("rocks-lpeg", { lpeg = { luarocks = "lpeg" } })
	app:installDependencies()
	local ok, err = app:runString([[
		local lpeg = require("lpeg")
		assert(lpeg.match(lpeg.R("09")^1, "42") == 3)
	]])
	test.truthy(ok)
end)

-- Disabled for macos: https://github.com/lde-org/lde/issues/90
test.skipIf(jit.os == "Windows" or jit.os == "OSX")("luarocks: luasocket parses a url", function()
	local app = makeApp("rocks-luasocket", { socket = { luarocks = "luasocket" } })
	app:installDependencies()
	local ok, err = app:runString([[
		local url = require("socket.url")
		local t = url.parse("https://example.com/path")
		assert(t.host == "example.com")
	]])
	test.truthy(ok)
end)

-- Disabled for macos: https://github.com/lde-org/lde/issues/90
test.skipIf(jit.os == "Windows" or jit.os == "OSX")("luarocks: lua-cjson encodes and decodes",
	function()
		local app = makeApp("rocks-cjson", { cjson = { luarocks = "lua-cjson" } })
		app:installDependencies()
		local ok, err = app:runString([[
		local cjson = require("cjson")
		local t = cjson.decode(cjson.encode({ x = 1 }))
		assert(t.x == 1)
	]])
		test.truthy(ok)
	end)

-- Skipped pending command build support on Windows/OSX
test.skipIf(jit.os == "Windows" or jit.os == "OSX")("luarocks: luaposix gets pid", function()
	local app = makeApp("rocks-luaposix", { posix = { luarocks = "luaposix" } })
	app:installDependencies()
	local ok, err = app:runString([[
		local unistd = require("posix.unistd")
		assert(unistd.getpid() > 0)
	]])
	test.truthy(ok)
end)
