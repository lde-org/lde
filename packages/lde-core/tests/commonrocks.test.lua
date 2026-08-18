local test = require("lde-test")
local lde = require("lde-core")
local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")

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

test.it("luarocks: lpeg matches a pattern", function()
	local app = makeApp("rocks-lpeg", { lpeg = { luarocks = "lpeg" } })
	app:installDependencies()
	local ok, err = app:runString([[
		local lpeg = require("lpeg")
		assert(lpeg.match(lpeg.R("09")^1, "42") == 3)
	]])
	test.truthy(ok)
end)

test.it("luarocks: luasocket parses a url", function()
	local app = makeApp("rocks-luasocket", { socket = { luarocks = "luasocket" } })
	app:installDependencies()
	local ok, err = app:runString([[
		local url = require("socket.url")
		local t = url.parse("https://example.com/path")
		assert(t.host == "example.com")
	]])
	test.truthy(ok)
end)

test.it("luarocks: lua-cjson encodes and decodes",
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

test.it("luarocks: teal compiler keeps its .tl source in target for tl check", function()
	local app = makeApp("rocks-tl", { tl = { luarocks = "tl" } })
	app:installDependencies()

	-- The tl rockspec lists "tl.tl" in build.install.lua (build.modules only
	-- carries the compiled tl.lua); it must land next to it so `tl check
	-- -I target` can resolve the module's types like lde package builds do.
	test.truthy(fs.isfile(path.join(app:getModulesDir(), "tl.lua")), "tl.lua not installed")
	test.truthy(fs.isfile(path.join(app:getModulesDir(), "tl.tl")), "tl.tl not kept in target")

	-- End-to-end: type-check a Teal snippet that requires the compiler. The run
	-- state's package.path is target/?, so tl resolves require("tl") to
	-- target/tl.tl - the same resolution `tl check -I target` performs.
	local ok, err = app:runString([=[
		local function fmtErrors(result)
			local out = {}
			for _, e in ipairs(result.type_errors or {}) do
				out[#out + 1] = (e.filename or "?") .. ":" .. tostring(e.y) .. ":" .. tostring(e.x) .. ": " .. (e.msg or "")
			end
			return table.concat(out, "\n")
		end

		local tl = require("tl")
		local env = tl.init_env(false, false, "5.1")
		local result = tl.process_string([[
			local compiler = require("tl")
			local v: string = compiler.version()
			return compiler
		]], false, env, "checkme.tl")
		assert(result and result.type_errors and #result.type_errors == 0,
			"tl check failed:\n" .. fmtErrors(result))
	]=])
	test.truthy(ok, err or "tl check of a require(\"tl\") snippet failed")
end)

local isAndroid = env.var("ANDROID_ROOT") ~= nil

-- Android: Skip because termux doesn't expose crypt symbols.
-- Windows: luaposix's luke build is POSIX-only (it splits PATH on ':' and
-- spawns via `sh -c`), so it can't build even with the bundled toolchain.
test.skipIf(isAndroid or jit.os == "Windows")("luarocks: luaposix gets pid", function()
	local app = makeApp("rocks-luaposix", { posix = { luarocks = "luaposix" } })
	app:installDependencies()
	local ok, err = app:runString([[
		local unistd = require("posix.unistd")
		assert(unistd.getpid() > 0)
	]])
	test.truthy(ok)
end)
