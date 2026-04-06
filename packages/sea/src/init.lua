local sea = {}

local process = require("process2")
local path = require("path")
local env = require("env")
local fs = require("fs")
local jit = require("jit")
local Archive = require("archive")

local util = require("util")

local ljDistRepo = "codebycruz/lj-dist"
local ljDistTag = "latest"

local function getPlatformArch()
	local platform = jit.os == "Linux" and "linux"
		or jit.os == "Windows" and "windows"
		or jit.os == "OSX" and "macos"
		or error("Unsupported platform: " .. jit.os)

	local arch = jit.arch == "x64" and "x86-64"
		or jit.arch == "arm64" and "aarch64"
		or error("Unsupported architecture: " .. jit.arch)

	return platform, arch
end

---@return "musl" | "gnu" | nil
local function getPlatformLibc()
	if jit.os == "OSX" then return nil end
	if jit.os == "Windows" then return "gnu" end

	-- note: for some reason 'ok' is nil here.
	local _code, out = process.exec("ldd", { "--version" })

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

	local code, _, stderr = process.exec("curl", { "-L", "-o", tarballPath, downloadUrl })
	if code ~= 0 then
		error("Failed to download LuaJIT from " .. downloadUrl .. ": " .. (stderr or ""))
	end

	local ok, err = Archive.new(tarballPath):extract(cacheDir)
	if not ok then
		error("Failed to extract LuaJIT: " .. (err or ""))
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

---@param main string # name used as the chunk label
---@param source string # bundled lua source (output of bundlePackage)
---@param sharedLibs? { name: string, content: string }[]
---@param compiler? string # path to compiler binary; defaults to SEA_CC env var or "gcc"
---@return string
function sea.compile(main, source, sharedLibs, compiler)
	local outPath = path.join(env.tmpdir(), "sea.out")
	sharedLibs = sharedLibs or {}

	local filePreloads

	-- For each shared library, emit a uint8_t array and the write+preload logic.
	-- The path is deterministic: /tmp/lde-lib-<name>-<hash>.so so that
	-- the file is only written once across runs with identical content.
	local libDecls = {}    -- top-level C declarations (arrays + path strings)
	local libStartup = {}  -- code that runs before lua_State is created
	local libPreloads = {} -- package.preload registrations
	local ffiShimEntries = {} -- name -> extracted path, for ffi.load shim

	for _, lib in ipairs(sharedLibs) do
		local id                            = safeIdent(lib.name)
		local hash                          = util.fnv1a(lib.content)
		local ext                           = jit.os == "Windows" and "dll"
			or jit.os == "OSX" and "dylib"
			or "so"
		local libPath                       = string.format("/tmp/lde-lib-%s-%s.%s", lib.name, hash, ext)
		ffiShimEntries[#ffiShimEntries + 1] = string.format('["%s"]="%s"', lib.name, libPath)
		-- alias as libcurl, libcurl.so, and curl
		local leaf                          = lib.name:match("[^.]+$")        -- e.g. "libcurl"
		local bare                          = leaf:match("^lib(.+)$") or leaf -- e.g. "curl"
		ffiShimEntries[#ffiShimEntries + 1] = string.format('["%s"]="%s"', leaf, libPath)
		ffiShimEntries[#ffiShimEntries + 1] = string.format('["%s.%s"]="%s"', leaf, ext, libPath)
		ffiShimEntries[#ffiShimEntries + 1] = string.format('["%s"]="%s"', bare, libPath)

		libDecls[#libDecls + 1]             = string.format(
			"static const uint8_t %sLibrary[] = {%s};",
			id, toByteLiteral(lib.content)
		)
		libDecls[#libDecls + 1]             = string.format(
			'static const char* %sLibraryPath = "%s";',
			id, libPath
		)

		libStartup[#libStartup + 1]         = string.format([[
	{
		FILE* f = fopen(%sLibraryPath, "rb");
		if (f == NULL) {
			f = fopen(%sLibraryPath, "wb");
			if (f == NULL) { perror("lde-sea: cannot write %s"); return 1; }
			fwrite(%sLibrary, 1, sizeof(%sLibrary), f);
			fclose(f);
		} else {
			fclose(f);
		}
	}]], id, id, lib.name, id, id)

		libPreloads[#libPreloads + 1]       = string.format([[
	lua_pushstring(L, %sLibraryPath);
	lua_pushcclosure(L, lde_loadlib_loader, 1);
	lua_setfield(L, -2, "%s");]], id, string.gsub(lib.name, ".", CEscapes))
	end

	local libDeclsStr    = table.concat(libDecls, "\n")
	local libStartupStr  = table.concat(libStartup, "\n")
	local libPreloadsStr = table.concat(libPreloads, "\n")

	if #ffiShimEntries > 0 then
		source = util.dedent(string.format([[
			do
				local _map = {%s}
				local _ffi = require("ffi")
				local _orig = _ffi.load
				_ffi.load = function(name, ...)
					local remap = _map[name] or _map[name:match("[^/\\]+$")]
					return _orig(remap or name, ...)
				end
			end
		]], table.concat(ffiShimEntries, ", "))) .. "\n" .. source
	end

	filePreloads        = {
		('luaL_loadbuffer(L, "%s", %d, "%s"); lua_setfield(L, -2, "%s");')
			:format(
				source:gsub(".", CEscapes),
				#source,
				"@" .. main:gsub(".", CEscapes),
				main:gsub(".", CEscapes)
			)
	}

	local hasLibs       = #sharedLibs > 0
	local stdintInclude = hasLibs and "#include <stdint.h>" or ""

	-- lde_loadlib_loader: a C closure that calls package.loadlib(upvalue1, "*").
	-- Only emitted when there are shared libs to avoid dead-code warnings.
	local loadlibHelper = ""
	if hasLibs then
		loadlibHelper = [[
static int lde_loadlib_loader(lua_State* L) {
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

	if jit.os == "Linux" then
		args[#args + 1] = "-lm"
		args[#args + 1] = "-ldl"
		args[#args + 1] = "-Wl,--export-dynamic" -- expose lua symbols for lua dependencies
	elseif jit.os == "OSX" then
		args[#args + 1] = "-Wl,-export_dynamic" -- expose lua symbols for lua dependencies
	end

	local compiler = compiler or env.var("SEA_CC") or "gcc"
	local execEnv
	if jit.os == "Windows" and compiler ~= "gcc" then
		-- compiler is a full path into mingw/bin; ensure subtools (as.exe etc) are found
		execEnv = { PATH = path.dirname(compiler) .. ";" .. (env.var("PATH") or "") }
	end
	local code, stdout, stderr = process.exec(compiler, args, { stdin = code, env = execEnv })
	if code ~= 0 or string.find(stderr or "", "is not recognized as an internal", 1, true) then
		error("Compilation failed: " .. (stderr or ""))
	end

	return outPath
end

return sea
