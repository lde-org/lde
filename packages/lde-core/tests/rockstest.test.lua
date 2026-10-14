local test = require("lde-test")
const lde = require("lde-core")
const fs = require("fs")
local path = require("path")
const env = require("env")
const md5 = require("lde-core.util.md5")

local tmpBase = path.join(env.tmpdir(), "lde-rockstest-tests")
fs.rmdir(tmpBase)
fs.mkdirAll(tmpBase)

---@param dir string
---@param files table<string, string>
local function writeTree(dir, files)
	for rel, content in pairs(files) do
		const abs = path.join(dir, rel)
		fs.mkdirAll(path.dirname(abs))
		fs.write(abs, content)
	end
end

--- A rockspec-backed package that runs its own test section.
---@param name string
---@param rockspec string
---@param files table<string, string>?
---@return lde.Package
local function openFixture(name, rockspec, files)
	local dir = path.join(tmpBase, name)
	fs.rmdir(dir)
	fs.mkdirAll(dir)
	writeTree(dir, files or {})
	fs.write(path.join(dir, name .. "-1.0-1.rockspec"), rockspec)
	local pkg = assert(lde.Package.openRockspec(dir))
	return pkg
end

test.it("md5 matches the RFC 1321 test vectors", function()
	test.equal(md5.sumhexa(""), "d41d8cd98f00b204e9800998ecf8427e")
	test.equal(md5.sumhexa("a"), "0cc175b9c0f1b6a831c399e269772661")
	test.equal(md5.sumhexa("abc"), "900150983cd24fb0d6963f7d28e17f72")
	test.equal(md5.sumhexa("message digest"), "f96b697d7cb7938d525a2f31aaf161d0")
	test.equal(md5.sumhexa("abcdefghijklmnopqrstuvwxyz"), "c3fcd3d76192e4007dfb496cca67e13b")
	test.equal(md5.sumhexa(string.rep("1234567890", 8)), "57edf4a22be3c955ac49da2e2107b67a")
	-- 55/56/57 bytes straddle the padding edge, where the length field needs a block of its own.
	test.equal(md5.sumhexa(string.rep("x", 55)), "04364420e25c512fd958a70738aa8f72")
	test.equal(md5.sumhexa(string.rep("x", 56)), "668a72d5ba17f08e62dabcafad6db14b")
	test.equal(md5.sumhexa(string.rep("x", 57)), "693037871c4a9d3d8685018905cb530a")
end)

--- Marks a fixture dir as extracted by the current layout ("2"), which is what a
--- fresh extraction writes; a marker-less dir counts as the legacy (stripped) layout.
---@param dir string
local function stampLayout(dir)
	fs.write(path.join(dir, ".lde-complete"), "2")
end

test.it("sourceDirFor prefers the declared source.dir", function()
	local root = path.join(tmpBase, "srcdir-declared")
	writeTree(root, { ["nested-1.0/init.lua"] = "return true", ["other/x.lua"] = "return true" })
	stampLayout(root)
	test.equal(lde.global.sourceDirFor(root, "nested-1.0"), path.join(root, "nested-1.0"))
end)

test.it("a legacy cache keeps the extraction root as the source dir", function()
	-- Dirs written before the layout was tracked were stripped during extraction,
	-- so the root already is the source tree; the declared dir no longer exists.
	local root = path.join(tmpBase, "srcdir-legacy")
	writeTree(root, { ["init.lua"] = "return true", ["other/x.lua"] = "return true" })
	test.equal(lde.global.sourceDirFor(root, "nested-1.0"), root)
end)

test.it("sourceDirFor falls back to the single top-level directory", function()
	local root = path.join(tmpBase, "srcdir-single")
	writeTree(root, { ["pkg-1.0/init.lua"] = "return true" })
	test.equal(lde.global.sourceDirFor(root), path.join(root, "pkg-1.0"))
end)

test.it("sourceDirFor keeps the root for multi-root and wrapper-less archives", function()
	local multi = path.join(tmpBase, "srcdir-multi")
	writeTree(multi, { ["a/x.lua"] = "", ["b/y.lua"] = "" })
	test.equal(lde.global.sourceDirFor(multi), multi, "a multi-root archive must not be merged")

	local flat = path.join(tmpBase, "srcdir-flat")
	writeTree(flat, { ["mod.lua"] = "return true" })
	test.equal(lde.global.sourceDirFor(flat), flat, "a wrapper-less archive extracts at the root")
end)

test.it("a declared source.dir that is missing falls back to the extraction root", function()
	local root = path.join(tmpBase, "srcdir-missing")
	writeTree(root, { ["pkg-1.0/init.lua"] = "return true" })
	test.equal(lde.global.sourceDirFor(root, "nope-2.0"), root)
end)

test.it("source.md5 is verified on download and a mismatch is rejected", function()
	-- An immutable tagged tarball, so the digest below stays valid. The check runs
	-- on fresh downloads, so each case clears the cache entry first.
	const url = "https://github.com/kikito/middleclass/archive/v4.1.1.tar.gz"
	const cacheDir = lde.global.getArchiveDir(url)

	fs.rmdir(cacheDir)
	local ok, err = pcall(lde.global.getOrInitArchive, url, false, { md5 = "00000000000000000000000000000000" })
	test.falsy(ok, "a wrong md5 must fail the download")
	test.includes(tostring(err), "MD5 check for")

	fs.rmdir(cacheDir)
	local ok2, dir = pcall(lde.global.getOrInitArchive, url, false,
		{ md5 = "94b4551032465cc80b888871c690a6c3" })
	test.truthy(ok2, "the matching md5 must be accepted: " .. tostring(dir))
	test.truthy(fs.isfile(path.join(cacheDir, "middleclass-4.1.1", "middleclass.lua")),
		"the verified archive is extracted")
end)

test.it("rockspec test.type = 'command' runs its command", function()
	local pkg = openFixture("cmd-test", [[
package = "cmd-test"
version = "1.0-1"
source = { url = "git://example.com/cmd-test" }
test = { type = "command", command = "$(LUA) -e \"os.exit(0)\"" }
build = { type = "builtin", modules = {} }
]])
	const results = pkg:runTests(nil, nil, {})
	test.equal(results.exitCode, 0, "the command exit code is the verdict")
	test.equal(results.failures, 0)
end)

test.it("rockspec test.type = 'command' reports a non-zero exit as a failure", function()
	local pkg = openFixture("cmd-test-fail", [[
package = "cmd-test-fail"
version = "1.0-1"
source = { url = "git://example.com/cmd-test-fail" }
test = { type = "command", command = "$(LUA) -e \"os.exit(3)\"" }
build = { type = "builtin", modules = {} }
]])
	const results = pkg:runTests(nil, nil, {})
	test.equal(results.exitCode, 3)
	test.equal(results.failures, 1)
end)

test.it("rockspec test.type = 'command' runs a declared script through Lua", function()
	local marker = path.join(tmpBase, "script-ran.txt")
	local pkg = openFixture("cmd-script", [[
package = "cmd-script"
version = "1.0-1"
source = { url = "git://example.com/cmd-script" }
test = { type = "command", script = "tests/run.lua" }
build = { type = "builtin", modules = {} }
]], { ["tests/run.lua"] = "local f = assert(io.open([[" .. marker .. "]], 'w')) f:write('ok') f:close()" })
	const results = pkg:runTests(nil, nil, {})
	test.equal(results.exitCode, 0)
	test.equal(fs.read(marker), "ok", "the script runs with the package dir as cwd")
end)

test.it("a missing declared test script is a clear error", function()
	local pkg = openFixture("cmd-script-missing", [[
package = "cmd-script-missing"
version = "1.0-1"
source = { url = "git://example.com/cmd-script-missing" }
test = { type = "command", script = "tests/nope.lua" }
build = { type = "builtin", modules = {} }
]])
	const results = pkg:runTests(nil, nil, {})
	test.truthy(results.error ~= nil, "a missing script must fail the run")
	test.includes(results.error or "", "does not exist")
end)

test.it("a test.lua next to the rockspec auto-detects the command backend", function()
	local pkg = openFixture("auto-command", [[
package = "auto-command"
version = "1.0-1"
source = { url = "git://example.com/auto-command" }
build = { type = "builtin", modules = {} }
]], { ["test.lua"] = "print('auto')" })
	const results = pkg:runTests(nil, nil, {})
	test.equal(results.exitCode, 0, "test.lua is detected and run")
	test.equal(results.failures, 0)
end)

test.it("a rockspec with no test section and no test.lua reports the LuaRocks message", function()
	local pkg = openFixture("no-suite", [[
package = "no-suite"
version = "1.0-1"
source = { url = "git://example.com/no-suite" }
build = { type = "builtin", modules = {} }
]])
	const results = pkg:runTests(nil, nil, {})
	test.includes(results.error or "", "could not detect test type")
end)

test.it("a custom luarocks.test.<type> backend runs in the sandbox", function()
	-- A published backend arrives as a luarocks-test-<type> test dependency; this
	-- fixture ships the module in its own tree, which the sandbox resolves the
	-- same way (packagePath points at the package's modules).
	local pkg = openFixture("custom-backend", [[
package = "custom-backend"
version = "1.0-1"
source = { url = "git://example.com/custom-backend" }
test = { type = "probe" }
build = {
	type = "builtin",
	modules = { ["luarocks.test.probe"] = "src/probe.lua" },
}
]], { ["src/probe.lua"] = [[
local probe = {}
function probe.run_tests(test, args)
	return nil, "probe backend ran with " .. tostring(#args) .. " args"
end
return probe
]] })
	const results = pkg:runTests(nil, nil, {})
	test.equal(results.failures, 1, "the backend's error is reported")
	test.includes(results.error or "", "probe backend ran with")
end)

test.it("a custom backend that succeeds passes the run", function()
	local pkg = openFixture("custom-backend-ok", [[
package = "custom-backend-ok"
version = "1.0-1"
source = { url = "git://example.com/custom-backend-ok" }
test = { type = "okprobe" }
build = {
	type = "builtin",
	modules = { ["luarocks.test.okprobe"] = "src/okprobe.lua" },
}
]], { ["src/okprobe.lua"] = [[
local probe = {}
function probe.run_tests(test, args)
	return true
end
return probe
]] })
	const results = pkg:runTests(nil, nil, {})
	test.equal(results.failures, 0)
	test.equal(results.exitCode, 0)
end)

--- The shape a luaunit rock uses: `test_dependencies = { "luaunit" }` plus a
--- command that runs the suite through the interpreter.
---@param name string
---@param body string
---@return lde.Package
local function luaunitFixture(name, body)
	return openFixture(name, [[
package = "]] .. name .. [["
version = "1.0-1"
source = { url = "git://example.com/]] .. name .. [[" }
test_dependencies = { "luaunit" }
test = { type = "command", command = "$(LUA) tests/suite.lua" }
build = { type = "builtin", modules = {} }
]], { ["tests/suite.lua"] = body })
end

test.it("command backend runs a luaunit suite from test_dependencies", function()
	local pkg = luaunitFixture("luaunit-pass", [[
local lu = require("luaunit")
TestSuite = {}
function TestSuite:testArithmetic() lu.assertEquals(1 + 1, 2) end
function TestSuite:testStrings() lu.assertStrContains("hello", "ell") end
os.exit(lu.LuaUnit.run())
]])
	const results = pkg:runTests(nil, nil, {})
	test.equal(results.exitCode, 0, "the luaunit suite must pass")
	test.equal(results.failures, 0)
end)

test.it("command backend reports a failing luaunit suite", function()
	local pkg = luaunitFixture("luaunit-fail", [[
local lu = require("luaunit")
TestSuite = {}
function TestSuite:testBroken() lu.assertEquals(1 + 1, 3) end
os.exit(lu.LuaUnit.run())
]])
	const results = pkg:runTests(nil, nil, {})
	test.falsy(results.exitCode == 0, "a failing suite must not exit 0")
	test.equal(results.failures, 1)
end)
