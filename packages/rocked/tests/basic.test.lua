local test = require("lde-test")
local rocked = require("rocked")

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
    ['busted.languages.ko']                   = 'busted/languages/ko.lua',
    ['busted.languages.nl']                   = 'busted/languages/nl.lua',
    ['busted.languages.pt-BR']                = 'busted/languages/pt-BR.lua',
    ['busted.languages.ro']                   = 'busted/languages/ro.lua',
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
