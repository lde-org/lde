local test = require("lde-test")
local rocked = require("rocked")

local fs = require("fs")
local path = require("path")

-- Unique tmp base without pulling in the env package (rocked keeps its dep
-- surface small): os.tmpname() returns a path inside the system temp dir.
local tmpBase = path.dirname(os.tmpname())

local BUSTED_ROCKSPEC = [==[
local package_name = "busted"
local package_version = "2.3.0"
local rockspec_revision = "1"
local github_account_name = "lunarmodules"
local github_repo_name = package_name

package = package_name
version = package_version .. "-" .. rockspec_revision

source = {
  url = "git+https://github.com/" .. github_account_name .. "/" .. github_repo_name .. ".git"
}

if package_version == "scm" then
  source.branch = "master"
else
  source.tag = "v" .. package_version
end

description = {
  summary = 'Elegant Lua unit testing',
  detailed = [[
    An elegant, extensible, testing framework.
    Ships with a large amount of useful asserts,
    plus the ability to write your own. Output
    in pretty or plain terminal format, JSON,
    or TAP for CI integration. Great for TDD
    and unit, integration, and functional tests.
  ]],
  homepage = "https://lunarmodules.github.io/busted/",
  license = 'MIT <http://opensource.org/licenses/MIT>'
}

dependencies = {
  'lua >= 5.1',
  'lua_cliargs >= 3.0',
  'luasystem >= 0.2.0',
  'dkjson >= 2.1.0',
  'say >= 1.4-1',
  'luassert >= 1.9.0-1',
  'lua-term >= 0.1',
  'penlight >= 1.15.0',
  'mediator_lua >= 1.1.1',
}

build = {
  type = 'builtin',
  modules = {
    ['busted.core']                           = 'busted/core.lua',
    ['busted.context']                        = 'busted/context.lua',
    ['busted.environment']                    = 'busted/environment.lua',
    ['busted.compatibility']                  = 'busted/compatibility.lua',
    ['busted.options']                        = 'busted/options.lua',
    ['busted.done']                           = 'busted/done.lua',
    ['busted.runner']                         = 'busted/runner.lua',
    ['busted.status']                         = 'busted/status.lua',
    ['busted.utils']                          = 'busted/utils.lua',
    ['busted.block']                          = 'busted/block.lua',
    ['busted.execute']                        = 'busted/execute.lua',
    ['busted.init']                           = 'busted/init.lua',
    ['busted.luajit']                         = 'busted/luajit.lua',
    ['busted.fixtures']                       = 'busted/fixtures.lua',

    ['busted.modules.configuration_loader']   = 'busted/modules/configuration_loader.lua',
    ['busted.modules.luacov']                 = 'busted/modules/luacov.lua',
    ['busted.modules.standalone_loader']      = 'busted/modules/standalone_loader.lua',
    ['busted.modules.test_file_loader']       = 'busted/modules/test_file_loader.lua',
    ['busted.modules.output_handler_loader']  = 'busted/modules/output_handler_loader.lua',
    ['busted.modules.helper_loader']          = 'busted/modules/helper_loader.lua',
    ['busted.modules.filter_loader']          = 'busted/modules/filter_loader.lua',
    ['busted.modules.cli']                    = 'busted/modules/cli.lua',

    ['busted.modules.files.lua']              = 'busted/modules/files/lua.lua',
    ['busted.modules.files.moonscript']       = 'busted/modules/files/moonscript.lua',
    ['busted.modules.files.terra']            = 'busted/modules/files/terra.lua',
    ['busted.modules.files.fennel']           = 'busted/modules/files/fennel.lua',

    ['busted.outputHandlers.base']            = 'busted/outputHandlers/base.lua',
    ['busted.outputHandlers.utfTerminal']     = 'busted/outputHandlers/utfTerminal.lua',
    ['busted.outputHandlers.plainTerminal']   = 'busted/outputHandlers/plainTerminal.lua',
    ['busted.outputHandlers.TAP']             = 'busted/outputHandlers/TAP.lua',
    ['busted.outputHandlers.json']            = 'busted/outputHandlers/json.lua',
    ['busted.outputHandlers.junit']           = 'busted/outputHandlers/junit.lua',
    ['busted.outputHandlers.gtest']           = 'busted/outputHandlers/gtest.lua',
    ['busted.outputHandlers.sound']           = 'busted/outputHandlers/sound.lua',

    ['busted.languages.ar']                   = 'busted/languages/ar.lua',
    ['busted.languages.de']                   = 'busted/languages/de.lua',
    ['busted.languages.en']                   = 'busted/languages/en.lua',
    ['busted.languages.es']                   = 'busted/languages/es.lua',
    ['busted.languages.fr']                   = 'busted/languages/fr.lua',
    ['busted.languages.is']                   = 'busted/languages/is.lua',
    ['busted.languages.it']                   = 'busted/languages/it.lua',
    ['busted.languages.ja']                   = 'busted/languages/ja.lua',
    ['busted.languages.nl']                   = 'busted/languages/nl.lua',
    ['busted.languages.pt-BR']                = 'busted/languages/pt-BR.lua',
    ['busted.languages.ru']                   = 'busted/languages/ru.lua',
    ['busted.languages.th']                   = 'busted/languages/th.lua',
    ['busted.languages.ua']                   = 'busted/languages/ua.lua',
    ['busted.languages.zh']                   = 'busted/languages/zh.lua',
  },
  install = {
    bin = {
      ['busted'] = 'bin/busted'
    }
  }
}
]==]

test.it("should be able to parse busted's rockspec", function()
	local ok, parsed = rocked.parse(BUSTED_ROCKSPEC)
	if not ok then
		error("Failed to parse rockspec: " .. parsed)
	end
	test.equal(parsed.package, "busted")
	test.equal(parsed.build.type, "builtin")
	test.equal(parsed.dependencies[2], "lua_cliargs >= 3.0")
end)

test.it("should be in a separate environment", function()
	local spec = [[
		print('i shouldnt be able to print')
	]]

	local ok, parsed = rocked.parse(spec)
	if ok then
		error("Expected rockspec to fail, but it succeeded")
	end ---@cast parsed string

	test.notEqual(parsed:find("attempt to call global 'print'"), nil)
end)

test.it("sandbox exposes only whitelisted globals", function()
	local ok, parsed = rocked.parse([[
		package = "globals-probe"
		version = "1.0-1"
		source = { url = "https://example.com" }
		build = {
			type = "builtin",
			modules = {
				["probe.os"]      = tostring(os ~= nil),
				["probe.io"]      = tostring(io ~= nil),
				["probe.debug"]   = tostring(debug ~= nil),
				["probe.print"]   = tostring(print ~= nil),
				["probe.load"]    = tostring(load ~= nil),
				["probe.jit"]     = tostring(jit ~= nil),
				["probe.math"]    = tostring(math ~= nil),
				["probe.string"]  = tostring(string ~= nil),
				["probe.pairs"]   = tostring(pairs ~= nil),
				["probe.require"] = tostring(require ~= nil),
			},
		}
	]])
	if not ok then
		error("probe parse failed: " .. tostring(parsed))
	end
	local m = parsed.build.modules
	test.equal(m["probe.os"], "false")
	test.equal(m["probe.io"], "false")
	test.equal(m["probe.debug"], "false")
	test.equal(m["probe.print"], "false")
	test.equal(m["probe.load"], "false")
	test.equal(m["probe.jit"], "false")
	test.equal(m["probe.math"], "true")
	test.equal(m["probe.string"], "true")
	test.equal(m["probe.pairs"], "true")
	test.equal(m["probe.require"], "true")
end)

test.it("shouldn't run for too long", function()
	local spec = [[
		while true do end
	]]

	local ok, parsed = rocked.parse(spec)
	if ok then
		error("Expected rockspec to fail, but it succeeded")
	end ---@cast parsed string

	test.notEqual(parsed:find("Rockspec took too long to run"), nil)
end)

--
-- rocked.parseDependency
--

test.it("parseDependency splits name and constraint at whitespace", function()
	local name, version = rocked.parseDependency("luafilesystem >= 1.8.0")
	test.equal(name, "luafilesystem")
	test.equal(version, ">= 1.8.0")
end)

test.it("parseDependency keeps dots in the package name", function()
	-- rocks.nvim deps like "fidget.nvim >= 1.1.0": the '.' must stay in the
	-- name, not leak into the constraint (previously parsed as fidget + ".nvim >= 1.1.0")
	local name, version = rocked.parseDependency("fidget.nvim >= 1.1.0")
	test.equal(name, "fidget.nvim")
	test.equal(version, ">= 1.1.0")
end)

test.it("parseDependency returns nil version for unconstrained deps", function()
	local name, version = rocked.parseDependency("luafilesystem")
	test.equal(name, "luafilesystem")
	test.equal(version, nil)
end)

test.it("parseDependency handles dashed names and exact-version deps", function()
	local name, version = rocked.parseDependency("lua-cjson 2.1.0.6")
	test.equal(name, "lua-cjson")
	test.equal(version, "2.1.0.6")
end)

--
-- rockspec format 3.0
--

test.it("parse defaults missing build to builtin for rockspec format 3.0+", function()
	local ok, parsed = rocked.parse([[
rockspec_format = "3.0"
package = "luarocks"
version = "3.13.0-1"
source = { url = "git+https://github.com/luarocks/luarocks" }
]])
	if not ok then
		error("Expected format 3.0 rockspec without build to parse: " .. tostring(parsed))
	end
	test.equal(parsed.build.type, "builtin")
end)

test.it("parse rejects missing build for rockspec formats older than 3.0", function()
	local ok, parsed = rocked.parse([[
rockspec_format = "2.0"
package = "oldpkg"
version = "1.0-1"
source = { url = "https://example.com" }
]])
	if ok then
		error("Expected old-format rockspec without build to fail")
	end ---@cast parsed string
	test.includes(parsed, "No build section found")
end)

--
-- custom build backends
--

local FAKE_BACKEND = [==[
local fs = require("luarocks.fs")
local dir = require("luarocks.dir")
local path = require("luarocks.path")
local cfg = require("luarocks.core.cfg")

local backend = {}
function backend.run(rockspec, no_install)
	assert(rockspec:type() == "rockspec", "rockspec:type()")
	assert(rockspec.name == "fake-rock", "rockspec.name")
	assert(cfg.lua_version == "5.1", "cfg.lua_version")
	assert(cfg.cache.luajit_version ~= nil, "cfg.cache.luajit_version")
	assert(cfg.is_platform("windows") == (cfg.external_lib_extension == "dll"), "cfg.is_platform")
	assert(fs.exists(rockspec.variables.LUA_INCDIR), "fs.exists")
	assert(path.lib_dir(rockspec.name, rockspec.version) == rockspec.variables.LUA_INCDIR, "path.lib_dir")
	local joined = dir.path("a", "b")
	assert(joined == "a/b" or joined:match("a[/\\]b"), "dir.path")
	return true
end
return backend
]==]

test.it("runBackend executes a custom backend in the sandbox", function()
	local base = path.join(tmpBase, "rocked-backend")
	fs.rmdir(base)
	fs.mkdirAll(path.join(base, "luarocks", "build"))
	fs.write(path.join(base, "luarocks", "build", "fake.lua"), FAKE_BACKEND)
	fs.write(path.join(base, "marker"), "x")

	local ok, err = rocked.runBackend("fake", {
		name = "fake-rock",
		version = "1.0-1",
		build = { type = "fake", modules = { "fake_mod" } },
		variables = { LUA_INCDIR = base },
	}, {
		packagePath = path.join(base, "?.lua") .. ";" .. path.join(base, "?", "init.lua"),
		libDir = base,
	})
	test.truthy(ok, err)
end)

test.it("runBackend surfaces backend errors", function()
	local base = path.join(tmpBase, "rocked-backend-fail")
	fs.rmdir(base)
	fs.mkdirAll(path.join(base, "luarocks", "build"))
	fs.write(path.join(base, "luarocks", "build", "failing.lua"), [[
		local backend = {}
		function backend.run(rockspec, no_install)
			error("boom")
		end
		return backend
	]])

	local ok, err = rocked.runBackend("failing", {
		name = "x",
		build = { type = "failing" },
	}, {
		packagePath = path.join(base, "?.lua") .. ";" .. path.join(base, "?", "init.lua"),
	})
	test.falsy(ok)
	test.includes(err, "boom")
end)

test.it("runBackend rejects a missing backend module", function()
	local ok, err = rocked.runBackend("does-not-exist", {
		name = "x",
		build = { type = "does-not-exist" },
	}, {
		packagePath = path.join(tmpBase, "rocked-nowhere", "?.lua"),
	})
	test.falsy(ok)
	test.truthy(err and err:find("luarocks.build.does-not-exist", 1, true))
end)

test.it("runBackend honors permissions callbacks", function()
	local base = path.join(tmpBase, "rocked-perms")
	fs.rmdir(base)
	fs.mkdirAll(path.join(base, "luarocks", "build"))
	fs.write(path.join(base, "luarocks", "build", "perm.lua"), [[
		local fs = require("luarocks.fs")
		local backend = {}
		function backend.run(rockspec, no_install)
			return fs.execute("echo hi > " .. rockspec.variables.OUT)
		end
		return backend
	]])

	local function rockspec()
		return {
			name = "x",
			version = "1.0-1",
			build = { type = "perm" },
			variables = { OUT = path.join(base, "out.txt") },
		}
	end
	local opts = {
		packagePath = path.join(base, "?.lua") .. ";" .. path.join(base, "?", "init.lua"),
	}

	-- Denied: the callback is consulted and the command never runs.
	local consulted = false
	local ok, err = rocked.runBackend("perm", rockspec(), {
		permissions = {
			execute = function(cmd)
				consulted = true
				return false
			end,
		},
		packagePath = opts.packagePath,
	})
	test.falsy(ok)
	test.truthy(consulted, "execute permission callback should be consulted")
	test.equal(fs.exists(path.join(base, "out.txt")), false)

	-- Allowed: default (no permissions table) and explicit allow both run.
	local ok2, err2 = rocked.runBackend("perm", rockspec(), opts)
	test.truthy(ok2, err2)
	local ok3, err3 = rocked.runBackend("perm", rockspec(), {
		permissions = { execute = function() return true end },
		packagePath = opts.packagePath,
	})
	test.truthy(ok3, err3)
end)
