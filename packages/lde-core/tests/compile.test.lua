local test = require("lde-test")

local lde = require("lde-core")
local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")
local process = require("process")

local tmpBase = path.join(env.tmpdir(), "lde-compile-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

test.it("compile: native C module is loadable in compiled binary", function()
		local rockDir = path.join(tmpBase, "answer-rock")
		fs.mkdir(rockDir)
		fs.mkdir(path.join(rockDir, "csrc"))

		fs.write(path.join(rockDir, "csrc", "answer.c"), [[
#include <stddef.h>
typedef struct lua_State lua_State;
typedef int (*lua_CFunction)(lua_State *L);
extern void lua_pushinteger(lua_State *L, ptrdiff_t n);
extern void lua_createtable(lua_State *L, int narr, int nrec);
extern void lua_setfield(lua_State *L, int idx, const char *k);
extern void lua_pushcclosure(lua_State *L, lua_CFunction fn, int n);
static int answer(lua_State *L) { lua_pushinteger(L, 52); return 1; }
int luaopen_answer(lua_State *L) {
	lua_createtable(L, 0, 1);
	lua_pushcclosure(L, answer, 0);
	lua_setfield(L, -2, "answer");
	return 1;
}
]])
		fs.write(path.join(rockDir, "answer-rock-1.0.0-1.rockspec"), [[
			package = "answer-rock"
			version = "1.0.0-1"
			source = { url = "git://example.com/answer-rock" }
			build = { type = "builtin", modules = { answer = "csrc/answer.c" } }
		]])

		local appDir = path.join(tmpBase, "answer-app")
		fs.mkdir(appDir)
		fs.mkdir(path.join(appDir, "src"))
		fs.write(path.join(appDir, "src", "init.lua"),
			'local m = require("answer"); assert(m.answer() == 52); print("ok")')
		fs.write(path.join(appDir, "lde.json"), json.encode({
			name = "answer-app",
			version = "0.1.0",
			dependencies = { ["answer-rock"] = { path = "../answer-rock" } }
		}))

		local app = lde.Package.open(appDir)
		app:build()
		app:installDependencies()

		local binTmp = app:compile()
		local binPath = path.join(appDir, "answer-app")
		if jit.os == "Windows" then binPath = binPath .. ".exe" end
		fs.move(binTmp, binPath)
		if jit.os ~= "Windows" then fs.chmod(binPath, tonumber("755", 8)) end
		test.truthy(fs.exists(binPath), "compiled binary should exist")

		local code, stdout, stderr = process.exec(binPath, {})
		test.equal(stdout and stdout:gsub("%s+$", ""), "ok", "binary output: " .. tostring(stderr))
	end)
