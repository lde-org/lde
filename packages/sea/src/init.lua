local sea = {}

local process = require("process")
local path = require("path")
local env = require("env")
local fs = require("fs")
local jit = require("jit")

local ljDistRepo = "codebycruz/lj-dist"
local ljDistTag = "latest"

local function getPlatformArch()
	local platform = process.platform == "linux" and "linux"
		or process.platform == "win32" and "windows"
		or process.platform == "darwin" and "macos"
		or error("Unsupported platform: " .. process.platform)

	local arch = jit.arch == "x64" and "x86-64"
		or jit.arch == "arm64" and "aarch64"
		or error("Unsupported architecture: " .. jit.arch)

	return platform, arch
end

---@return "musl" | "gnu" | nil
local function getPlatformLibc()
	if process.platform == "darwin" then return nil end
	if process.platform == "windows" then return "gnu" end

	-- note: for some reason 'ok' is nil here.
	local _ok, out = process.exec("ldd", { "--version" })

	if string.find(out, "musl", 1, true) then
		return "musl"
	end

	return "gnu"
end

local function getLuajitPath()
	local cacheDir = path.join(env.tmpdir(), "luajit-cache")
	local platform, arch = getPlatformArch()
	local libc = getPlatformLibc()

	local target = table.concat({ "libluajit", platform, arch, libc }, "-")
	local targetDir = path.join(cacheDir, target)

	if fs.exists(path.join(targetDir, "include", "lua.h")) then
		return targetDir
	end

	fs.mkdir(cacheDir)

	local tarballName = target .. ".tar.gz"
	local downloadUrl = string.format(
		"https://github.com/%s/releases/download/%s/%s",
		ljDistRepo,
		ljDistTag,
		tarballName
	)
	local tarballPath = path.join(cacheDir, tarballName)

	local success, output = process.exec("curl", { "-L", "-o", tarballPath, downloadUrl })
	if not success then
		error("Failed to download LuaJIT from " .. downloadUrl .. ": " .. output)
	end

	local success, output = process.exec("tar", { "-xzf", tarballPath, "-C", cacheDir })
	if not success then
		error("Failed to extract LuaJIT: " .. output)
	end

	fs.delete(tarballPath)

	return targetDir
end



sea.getLuajitPath = getLuajitPath

local CEscapes = {
	["\a"] = "\\a",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
	["\v"] = "\\v",
	['"'] = '\\"',
	["\\"] = "\\\\"
}

---Compute a simple 32-bit FNV-1a hash of a string, returned as an 8-char hex string.
local function fnv1a(s)
	local h = 2166136261
	for i = 1, #s do
		h = bit.bxor(h, string.byte(s, i))
		h = bit.band(h * 16777619, 0xFFFFFFFF)
	end
	return string.format("%08x", bit.band(h, 0xFFFFFFFF))
end

---Convert binary content to a C uint8_t array initialiser string, e.g. "0x41,0x42,..."
local function toByteLiteral(content)
	local t = {}
	for i = 1, #content do
		t[i] = string.format("0x%02x", string.byte(content, i))
	end
	return table.concat(t, ",")
end

---Sanitise a library name so it is safe to use as a C identifier.
local function safeIdent(name)
	return string.gsub(name, "[^%w]", "_")
end

---@param content string
---@param chunkName string
function sea.bytecode(content, chunkName)
	local success, bytecode = process.exec("luajit", { "-b", "-g", "-F", chunkName, "-", "-" }, { stdin = content })

	if not success then
		error("Failed to compile bytecode: " .. bytecode)
	end

	return bytecode
end

---@param main string
---@param files { path: string, content: string }[]
---@param sharedLibs? { name: string, content: string }[]
---@return string
function sea.compile(main, files, sharedLibs)
	local outPath = path.join(env.tmpdir(), "sea.out")
	sharedLibs = sharedLibs or {}

	-- Build preload entries for Lua source modules.
	local filePreloads = {}
	for i, file in ipairs(files) do
		local escapedName = file.path:gsub(".", CEscapes)

		filePreloads[i] = ('luaL_loadbuffer(L, "%s", %d, "%s"); lua_setfield(L, -2, "%s");')
			:format(
				file.content:gsub(".", CEscapes),
				#file.content,
				"@" .. escapedName,
				escapedName
			)
	end

	-- For each shared library, emit a uint8_t array and the write+preload logic.
	-- The path is deterministic: /tmp/lpm-lib-<name>-<hash>.so so that
	-- the file is only written once across runs with identical content.
	local libDecls = {} -- top-level C declarations (arrays + path strings)
	local libStartup = {} -- code that runs before lua_State is created
	local libPreloads = {} -- package.preload registrations

	for _, lib in ipairs(sharedLibs) do
		local id                      = safeIdent(lib.name)
		local hash                    = fnv1a(lib.content)
		local ext                     = process.platform == "win32" and "dll"
			or process.platform == "darwin" and "dylib"
			or "so"
		local libPath                 = string.format("/tmp/lpm-lib-%s-%s.%s", lib.name, hash, ext)

		libDecls[#libDecls + 1]       = string.format(
			"static const uint8_t %sLibrary[] = {%s};",
			id, toByteLiteral(lib.content)
		)
		libDecls[#libDecls + 1]       = string.format(
			'static const char* %sLibraryPath = "%s";',
			id, libPath
		)

		libStartup[#libStartup + 1]   = string.format([[
	{
		FILE* f = fopen(%sLibraryPath, "rb");
		if (f == NULL) {
			f = fopen(%sLibraryPath, "wb");
			if (f == NULL) { perror("lpm-sea: cannot write %s"); return 1; }
			fwrite(%sLibrary, 1, sizeof(%sLibrary), f);
			fclose(f);
		} else {
			fclose(f);
		}
	}]], id, id, lib.name, id, id)

		libPreloads[#libPreloads + 1] = string.format([[
	lua_pushstring(L, %sLibraryPath);
	lua_pushcclosure(L, lpm_loadlib_loader, 1);
	lua_setfield(L, -2, "%s");]], id, string.gsub(lib.name, ".", CEscapes))
	end

	local libDeclsStr    = table.concat(libDecls, "\n")
	local libStartupStr  = table.concat(libStartup, "\n")
	local libPreloadsStr = table.concat(libPreloads, "\n")

	local hasLibs        = #sharedLibs > 0
	local stdintInclude  = hasLibs and "#include <stdint.h>" or ""

	-- lpm_loadlib_loader: a C closure that calls package.loadlib(upvalue1, "*").
	-- Only emitted when there are shared libs to avoid dead-code warnings.
	local loadlibHelper  = ""
	if hasLibs then
		loadlibHelper = [[
static int lpm_loadlib_loader(lua_State* L) {
	const char* soPath = lua_tostring(L, lua_upvalueindex(1));
	lua_getglobal(L, "package");
	lua_getfield(L, -1, "loadlib");
	lua_pushstring(L, soPath);
	lua_pushstring(L, "*");
	if (lua_pcall(L, 2, 1, 0) != LUA_OK) {
		return luaL_error(L, "loadlib failed for %s: %s", soPath, lua_tostring(L, -1));
	}
	return 1;
}
]]
	end

	local code = stdintInclude .. [[
#include <stdio.h>
#include "lauxlib.h"
#include "lualib.h"

]] .. libDeclsStr .. [[

]] .. loadlibHelper .. [[

int traceback(lua_State* L) {
	const char* msg = lua_tostring(L, 1);
	if (msg == NULL) {
		msg = "(error object is not a string)";
	}

	luaL_traceback(L, L, msg, 1);
	return 1;
}

int main(int argc, char** argv) {
]] .. libStartupStr .. [[

	lua_State* L = luaL_newstate();
	luaL_openlibs(L);

	lua_getglobal(L, "package");
	lua_getfield(L, -1, "preload");

	]] .. table.concat(filePreloads, "\n\t") .. [[

	]] .. libPreloadsStr .. [[

	lua_getfield(L, -1, "]] .. main:gsub(".", CEscapes) .. [[");

	for (int i = 1; i < argc; i++) {
		lua_pushstring(L, argv[i]);
	}

	int base = lua_gettop(L) - (argc - 1);
	lua_pushcfunction(L, traceback);
	lua_insert(L, base);

	int result = lua_pcall(L, argc - 1, 0, base);
	if (result != LUA_OK) {
		fprintf(stderr, "%s\n", lua_tostring(L, -1));
		lua_close(L);
		return 1;
	}

	lua_close(L);
	return 0;
}
]]

	local ljPath = getLuajitPath()
	local includePath = path.join(ljPath, "include")
	local libPath = path.join(ljPath, "lib")

	local args = {
		"-I" .. includePath,
		"-xc", "-",
		"-o", outPath,
		"-xnone", path.join(libPath, "libluajit.a")
	}

	if process.platform == "linux" then
		args[#args + 1] = "-lm"
		args[#args + 1] = "-ldl"
		args[#args + 1] = "-Wl,--export-dynamic" -- expose lua symbols for lua dependencies
	elseif process.platform == "darwin" then
		args[#args + 1] = "-Wl,-export_dynamic" -- expose lua symbols for lua dependencies
	end

	local compiler = env.var("SEA_CC") or "gcc"
	local success, output = process.exec(compiler, args, { stdin = code })
	if not success or string.find(output, "is not recognized as an internal", 1, true) then
		error("Compilation failed: " .. output)
	end

	return outPath
end

return sea
