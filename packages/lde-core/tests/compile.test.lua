local test = require("lde-test")

local lde = require("lde-core")
local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")
local process = require("process")
local sea = require("sea")

local tmpBase = path.join(env.tmpdir(), "lde-compile-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

--- The release target matching the host (nil when none does — e.g. a musl
--- host or an arch lde doesn't ship).
---@return string?
local function hostTargetName()
	local host = sea.getHostTarget()
	for name, target in pairs(sea.targets) do
		if target.platform == host.platform and target.arch == host.arch
			and (target.libc or "") == (host.libc or "") then
			return name
		end
	end
	return nil
end

--- Any release target that is not the host (a genuine cross compile).
---@return string
local function crossTargetName()
	for name, target in pairs(sea.targets) do
		if not sea.isHostTarget(target) then return name end
	end
	error("no cross target available on this host", 0)
end

---@param name string
---@return string dir
local function makeApp(name)
	local dir = path.join(tmpBase, name)
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), 'print("' .. name .. '-ok")')
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = name,
		version = "0.1.0",
		dependencies = {}
	}))
	return dir
end

--- Seed the LuaJIT dist cache for a target with a fake include/lua.h so a
--- compile skips the download (sea only checks for that file). Returns the
--- created dist dir for cleanup, or nil when a real dist was already cached.
---@param targetName string
---@return string?
local function fakeDistCache(targetName)
	local target = assert(sea.getTarget(targetName))
	local distName = table.concat({ "libluajit", target.platform, target.arch, target.libc }, "-")
	local distDir = path.join(sea.getLuajitCacheDir(), distName)
	if fs.exists(path.join(distDir, "include", "lua.h")) then
		return nil
	end
	fs.mkdirAll(path.join(distDir, "include"))
	fs.write(path.join(distDir, "include", "lua.h"), "")
	return distDir
end

--- Run `fn` with LDE_HOME pointed at a throwaway home under tmpBase, so the
--- fake dists seeded by tests land in a temp cache. The real cache lives in the
--- user lde dir (~/.lde/luajit) and is what actual compiles use: a faked
--- include/lua.h must never shadow a real dist there, and a fake left behind by
--- a failed run would outlive the test. Restores LDE_HOME and removes the fake
--- home afterwards either way.
---@param name string # unique per call: each fake home gets its own dir
---@param fn fun()
local function withFakeLdeHome(name, fn)
	local home = path.join(tmpBase, "lde-home-" .. name)
	local saved = env.var("LDE_HOME")
	env.set("LDE_HOME", home)
	local ok, err = pcall(fn)
	fs.rmdir(home)
	env.set("LDE_HOME", saved)
	if not ok then error(err, 0) end
end

test.it("compile: the LuaJIT dist cache follows LDE_HOME", function()
	local saved = env.var("LDE_HOME")
	local home = path.join(tmpBase, "lde-home-location")
	env.set("LDE_HOME", home)
	local cacheDir = sea.getLuajitCacheDir()
	env.set("LDE_HOME", saved)

	test.equal(cacheDir, path.join(home, "luajit"), "the dist cache belongs to the lde home")
end)

test.it("compile: the LuaJIT dist cache defaults to ~/.lde, not the temp dir", function()
	local saved = env.var("LDE_HOME")
	env.set("LDE_HOME", nil)
	local cacheDir = sea.getLuajitCacheDir()
	env.set("LDE_HOME", saved)

	local home = env.var("HOME") or env.var("USERPROFILE")
	test.truthy(home, "tests need HOME or USERPROFILE set")
	test.equal(cacheDir, path.join(home, ".lde", "luajit"), "the temp dir is wiped on reboot")
end)

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

		local app = lde.Package.open(appDir) ---@cast app -nil
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

test.skipIf(hostTargetName() == nil)("compile: --target matching the host is a native build", function()
	local name = assert(hostTargetName())
	local dir = makeApp("target-native")

	local app = lde.Package.open(dir) ---@cast app -nil
	local binTmp = app:compile(name)
	local binPath = path.join(dir, "target-native")
	if jit.os == "Windows" then binPath = binPath .. ".exe" end
	fs.move(binTmp, binPath)
	if jit.os ~= "Windows" then fs.chmod(binPath, tonumber("755", 8)) end
	test.truthy(fs.exists(binPath), "compiled binary should exist")

	local code, stdout, stderr = process.exec(binPath, {})
	test.truthy(code == 0, "compiled binary failed: " .. tostring(stderr))
	test.includes(stdout or "", "target-native-ok")
end)

test.it("compile: unknown --target fails cleanly before building", function()
	local dir = makeApp("target-unknown")

	local app = lde.Package.open(dir) ---@cast app -nil
	local ok, err = pcall(function() app:compile("not-a-target") end)
	test.falsy(ok, "unknown target must fail")
	local msg = tostring(err)
	test.includes(msg, "Unknown compile target 'not-a-target'")
	test.includes(msg, "expected one of")
	test.includes(msg, "windows-x86-64")
end)

test.it("compile: cross --target flows the target into build scripts", function()
	local dir = makeApp("target-buildinfo")
	-- The build script records build.target and runs build:cc() (a query, so
	-- it works without a target sysroot). The compile itself may then fail or
	-- succeed depending on whether a toolchain for the target exists — only
	-- the recorded target info is asserted.
	fs.write(path.join(dir, "build.lua"), [[
local build = require("lde-build")
local out = build:cc({ "-dumpmachine" })
build:write("target-info.txt", build.target .. "\n" .. out)
]])

	local app = lde.Package.open(dir) ---@cast app -nil
	local crossName = crossTargetName()
	withFakeLdeHome("target-buildinfo", function()
		fakeDistCache(crossName)
		-- The compile may fail without a toolchain for the target — only the
		-- recorded target info, asserted below, is under test.
		pcall(function() app:compile(crossName) end)
	end)

	local info = assert(fs.read(path.join(dir, "target", "target-buildinfo", "target-info.txt")),
		"build script should have run under the cross target")
	local target = assert(sea.getTarget(crossName))
	-- build.target is the clang triple; build:cc() prefixed -target so the
	-- dumpmachine query reports the target's triple.
	local firstLine = assert(info:match("^([^\n]*)"))
	test.equal(firstLine, target.triple, "build.target should be the target triple")
	test.includes(info, target.triple)
end)

test.it("compile: switching --target rebuilds native deps for the new target", function()
	local dir = makeApp("target-switch")
	-- The build script stamps its output with build.target; switching --target
	-- must invalidate the build stamp so the script re-runs.
	fs.write(path.join(dir, "build.lua"), [[
local build = require("lde-build")
build:write("target-info.txt", build.target)
]])

	local app = lde.Package.open(dir) ---@cast app -nil
	local firstTarget = crossTargetName()
	withFakeLdeHome("target-switch-1", function()
		fakeDistCache(firstTarget)
		pcall(function() app:compile(firstTarget) end)
	end)
	local info1 = assert(fs.read(path.join(dir, "target", "target-switch", "target-info.txt")))

	local secondTarget
	for name, target in pairs(sea.targets) do
		if name ~= firstTarget and not sea.isHostTarget(target) then secondTarget = name break end
	end
	test.truthy(secondTarget, "need a second cross target") ---@cast secondTarget -nil
	withFakeLdeHome("target-switch-2", function()
		fakeDistCache(secondTarget)
		pcall(function() app:compile(secondTarget) end)
	end)
	local info2 = assert(fs.read(path.join(dir, "target", "target-switch", "target-info.txt")))

	test.falsy(info1 == info2, "build script must re-run when the target changes")
	test.equal(info2, assert(sea.getTarget(secondTarget)).triple,
		"second build should target " .. secondTarget)
end)

test.it("compile: cross target context selects the cross compiler and flags", function()
	local cross = assert(sea.getTarget(crossTargetName()))
	lde.global.setTarget(cross)

	local flag = lde.global.getTargetFlag()
	local ccCommand = lde.global.getCCCommand()
	local ok, cc = pcall(lde.global.getCCBin)

	lde.global.setTarget(nil)

	test.equal(flag, "--target=" .. cross.triple) ---@cast flag -nil
	test.truthy(ccCommand:find(flag, 1, true), "CC command should carry the -target flag")
	test.equal(lde.global.getTarget(), nil, "target context must be reset")

	-- getCCBin must resolve a clang for cross builds (unless SEA_CC is set to
	-- something else, or no clang exists — a machine with only gcc).
	if ok and not env.var("SEA_CC") then
		local _, out = process.exec(cc, { "--version" })
		test.truthy(out and out:find("clang", 1, true), "cross compiler should be clang, got: " .. tostring(cc))
	end
end)

test.it("compile: sea targets match the LuaJIT dist release assets", function()
	-- Each release target must resolve to the libluajit-* tarball that
	-- lde-org/luajit actually publishes (verified against the release assets).
	---@type table<string, string>
	local expectedDists = {
		["linux-x86-64"]    = "libluajit-linux-x86-64-gnu",
		["linux-aarch64"]   = "libluajit-linux-aarch64-gnu",
		["windows-x86-64"]  = "libluajit-windows-x86-64-gnu",
		["windows-aarch64"] = "libluajit-windows-aarch64-gnu",
		["macos-x86-64"]    = "libluajit-macos-x86-64",
		["macos-aarch64"]   = "libluajit-macos-aarch64",
		["freebsd-x86-64"]  = "libluajit-freebsd-x86-64",
		["freebsd-aarch64"] = "libluajit-freebsd-aarch64",
		["android-aarch64"] = "libluajit-linux-aarch64-android",
	}

	for name in pairs(sea.targets) do
		test.truthy(expectedDists[name] ~= nil, "no expected LuaJIT dist for target " .. name)
	end

	withFakeLdeHome("dist-names", function()
		local cacheDir = sea.getLuajitCacheDir()
		for name, distName in pairs(expectedDists) do
			-- Fake the cache so getLuajitPath returns the dir without downloading.
			local dir = path.join(cacheDir, distName, "include")
			fs.mkdirAll(dir)
			fs.write(path.join(dir, "lua.h"), "")

			local target = assert(sea.getTarget(name))
			local targetDir = sea.getLuajitPath("gcc", target)
			test.equal(targetDir, path.join(cacheDir, distName),
				"luajit dist for " .. name .. " must resolve inside the dist cache")
		end
	end)

	-- Unknown targets are rejected with the valid list.
	local _, err = sea.getTarget("x86_64-pc-linux-gnu")
	test.includes(tostring(err or ""), "expected one of")
end)
