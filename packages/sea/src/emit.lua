--- Emits the C launcher source for a bundled Lua or LuaJIT bytecode payload:
--- embeds the shared libraries and bytecode blobs and wires up package.preload
--- and the ffi.load shim. Driven by sea.compile in the sea facade.

const path = require("path")
const env = require("env")
const fs = require("fs")
const util = require("util")

const emit = {}

const CEscapes = {
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

---Sanitise a library name so it is safe to use as a C identifier.
---@param name string
local function safeIdent(name)
	return (string.gsub(name, "[^%w]", "_"))
end

---@param main string # name used as the chunk label
---@param source string|{ name: string, modules: { name: string, code: string }[] } # bundled lua: source string, LuaJIT bytecode string, or a raw bytecode table (bundlePackage { raw = true })
---@param sharedLibs { name: string, content: string }[]
---@param platform string # "linux" | "windows" | "macos" | "freebsd"
function emit.buildSource(main, source, sharedLibs, platform)
	const libExt = platform == "windows" and "dll" or "so"

	-- For each shared library, emit a uint8_t array and the write+preload logic.
	-- The path is deterministic: /tmp/lde-lib-<name>-<hash>.so so that
	-- the file is only written once across runs with identical content.
	local libDecls = {}    -- top-level C declarations (arrays + path strings)
	local libStartup = {}  -- code that runs before lua_State is created
	local libPreloads = {} -- package.preload registrations
	local ffiShimEntries = {} -- name -> extracted path, for ffi.load shim

	for _, lib in ipairs(sharedLibs or {}) do
		local id                            = safeIdent(lib.name)
		local hash                          = util.hash(lib.content)
		const libFileName                   = string.format("lde-lib-%s-%s.%s", lib.name, hash, libExt)
		ffiShimEntries[#ffiShimEntries + 1] = string.format('["%s"]="%s"', lib.name, libFileName)
		-- alias as libcurl, libcurl.so/libcurl.dylib, and curl
		local leaf                          = lib.name:match("[^.]+$")  -- e.g. "libcurl"
		local bare                          = leaf:match("^lib(.+)$") or leaf -- e.g. "curl"
		ffiShimEntries[#ffiShimEntries + 1] = string.format('["%s"]="%s"', leaf, libFileName)
		if platform == "windows" then
			ffiShimEntries[#ffiShimEntries + 1] = string.format('["%s.dll"]="%s"', leaf, libFileName)
		else
			-- Runtime code may load the library by either a LuaJIT-style .so name
			-- or a platform .dylib name (e.g. git2-sys calls
			-- ffi.load("libgit2.dylib") on macOS); map both to the embedded copy.
			ffiShimEntries[#ffiShimEntries + 1] = string.format('["%s.so"]="%s"', leaf, libFileName)
			ffiShimEntries[#ffiShimEntries + 1] = string.format('["%s.dylib"]="%s"', leaf, libFileName)
		end
		ffiShimEntries[#ffiShimEntries + 1] = string.format('["%s"]="%s"', bare, libFileName)

		-- Embed the library as a raw blob via an .incbin assembler directive
		-- instead of a C byte-array literal: a 1MB .so would otherwise become
		-- ~5MB of "0xNN," tokens that gcc has to lex and parse. The blob is
		-- written to the same content-addressed path the compiled binary's
		-- startup uses, so the assembler pass and the runtime share one file.
		local libPath = path.join(env.tmpdir(), libFileName)
		if not fs.exists(libPath) then
			fs.write(libPath, lib.content)
		end

		local asmPath = libPath:gsub("\\", "/"):gsub('"', '\\"')
		libDecls[#libDecls + 1]             = string.format([[

#if defined(__APPLE__)
__asm__(".globl _%s_lib_start\n_%s_lib_start:\n.incbin \"%s\"\n.globl _%s_lib_end\n_%s_lib_end:\n");
#else
__asm__(".globl %s_lib_start\n%s_lib_start:\n.incbin \"%s\"\n.globl %s_lib_end\n%s_lib_end:\n");
#endif
extern const unsigned char %s_lib_start[];
extern const unsigned char %s_lib_end[];
]], id, id, asmPath, id, id, id, id, asmPath, id, id, id, id)
		libDecls[#libDecls + 1]             = string.format(
			'static const char %sLibraryName[] = "%s";',
			id, libFileName
		)
		libDecls[#libDecls + 1]             = string.format(
			"static char %sLibraryPath[4096];",
			id
		)

		libStartup[#libStartup + 1]         = string.format([[
	{
		snprintf(%sLibraryPath, sizeof(%sLibraryPath), "%%s/%%s", lde_tmpdir, %sLibraryName);
		FILE* f = fopen(%sLibraryPath, "rb");
		if (f == NULL) {
			f = fopen(%sLibraryPath, "wb");
			if (f == NULL) { perror("lde-sea: cannot write %s"); return 1; }
			fwrite(%s_lib_start, 1, %s_lib_end - %s_lib_start, f);
			fclose(f);
		} else {
			fclose(f);
		}
	}]], id, id, id, id, id, lib.name, id, id, id)

		local luaopenSym                    = "luaopen_" .. lib.name:gsub("[%.-]", "_")
		libPreloads[#libPreloads + 1]       = string.format([[
	lua_pushstring(L, %sLibraryPath);
	lua_pushstring(L, "%s");
	lua_pushcclosure(L, lde_loadlib_loader, 2);
	lua_setfield(L, -2, "%s");]], id, luaopenSym, string.gsub(lib.name, ".", CEscapes))
	end

	const hasLibs        = #sharedLibs > 0
	const libDeclsStr    = table.concat(libDecls, "\n")
	const libTmpDirInit  = not hasLibs ? "" : [[
char lde_tmpdir[4096];
{
#ifdef _WIN32
	const char* lde_tmp_env = getenv("TEMP");
	if (!lde_tmp_env) lde_tmp_env = getenv("TMP");
	if (!lde_tmp_env) lde_tmp_env = "C:\\Windows\\Temp";
#else
	const char* lde_tmp_env = getenv("TMPDIR");
	if (!lde_tmp_env) lde_tmp_env = "/tmp";
#endif
	snprintf(lde_tmpdir, sizeof(lde_tmpdir), "%s", lde_tmp_env);
	size_t lde_tmp_len = strlen(lde_tmpdir);
	while (lde_tmp_len > 1 && (lde_tmpdir[lde_tmp_len-1] == '/' || lde_tmpdir[lde_tmp_len-1] == '\\')) {
		lde_tmpdir[--lde_tmp_len] = '\0';
	}
}
]]
	const libStartupStr  = libTmpDirInit .. table.concat(libStartup, "\n")
	const libPreloadsStr = table.concat(libPreloads, "\n")

	local ffiShim = ""
	if #ffiShimEntries > 0 then
		ffiShim = util.dedent(string.format([[
			do
				local _ffi = require("ffi")
				local _tmpdir
				if _ffi.os == "Windows" then
					_tmpdir = os.getenv("TEMP") or os.getenv("TMP") or "C:\\Windows\\Temp"
				else
					_tmpdir = os.getenv("TMPDIR") or "/tmp"
				end
				_tmpdir = _tmpdir:gsub("[\\\\/]+$", "")
				local _names = {%s}
				local _map = {}
				for k, v in pairs(_names) do _map[k] = _tmpdir .. "/" .. v end
				local _orig = _ffi.load
				_ffi.load = function(name, ...)
					local remap = _map[name] or _map[name:match("[^/\\\\]+$")]
					return _orig(remap or name, ...)
				end
			end
		]], table.concat(ffiShimEntries, ", ")))
	end

	-- Remaps ffi.load to the embedded shared libs. Kept as its own chunk
	-- (instead of being prepended to the bundle) so it works for both source
	-- and bytecode bundles.
	const shimSource = ffiShim
	local shimStartup = ""
	if shimSource ~= "" then
		shimStartup = string.format(
			'luaL_loadbuffer(L, "%s", %d, "@shim"); if (lua_pcall(L, 0, 0, 0) != LUA_OK) { fprintf(stderr, "%%s\\n", lua_tostring(L, -1)); return 1; }',
			shimSource:gsub(".", CEscapes),
			#shimSource
		)
	end

	const isRawBundle = type(source) == "table"
	const isBytecode  = not isRawBundle and (source --[[@as string]]):sub(1, 3) == "\27LJ"

	-- Link a raw byte blob into the binary (1:1 size, zero runtime decode).
	-- The path is content-addressed so recompiles of unchanged code reuse the
	-- file; returns the C declarations (asm + externs) for the blob.
	---@param content string
	local function writeBundleBlob(content)
		local hash   = util.hash(content)
		local bcPath = path.join(env.tmpdir(), "lde-bundle-" .. hash .. ".bc")
		if not fs.exists(bcPath) then
			fs.write(bcPath, content)
			if not fs.exists(bcPath) then
				error("Failed to write bundle bytecode to " .. bcPath)
			end
		end

		-- Forward slashes keep the path valid in .incbin on Windows; the asm
		-- symbol name differs on macOS (Mach-O prefixes C symbols with _).
		-- Blank line after [[ so the #if lands at the start of a line (Lua
		-- long brackets swallow the first newline).
		local asmPath = bcPath:gsub("\\", "/"):gsub('"', '\\"')
		return string.format([[

#if defined(__APPLE__)
__asm__(".globl _lde_bundle_start\n_lde_bundle_start:\n.incbin \"%s\"\n.globl _lde_bundle_end\n_lde_bundle_end:\n");
#else
__asm__(".globl lde_bundle_start\nlde_bundle_start:\n.incbin \"%s\"\n.globl lde_bundle_end\nlde_bundle_end:\n");
#endif
extern const unsigned char lde_bundle_start[];
extern const unsigned char lde_bundle_end[];
]], asmPath, asmPath)
	end

	local bundleDecls  = ""
	local loaderHelper = ""
	local filePreloads = {}
	local preloadSetup = {}
	local mainLoad     = ""

	if isRawBundle then
		-- bundlePackage raw mode: per-module bytecode is concatenated into one
		-- blob and the C side registers lazy package.preload loaders over it.
		-- Only the main entry is loaded eagerly (it needs argv); everything else
		-- deserializes on first require(), so --version/help never touch the
		-- whole module graph.
		const blobParts = {}
		const modules   = {}
		local offset    = 0
		for _, m in ipairs(source.modules) do
			modules[#modules + 1] = {
				name      = m.name,
				chunkname = "@" .. m.name,
				off       = offset,
				len       = #m.code,
				aliases   = m.aliases
			}
			blobParts[#blobParts + 1] = m.code
			offset += #m.code
		end
		bundleDecls = writeBundleBlob(table.concat(blobParts))

		local modEntries = {}
		for _, m in ipairs(modules) do
			modEntries[#modEntries + 1] = string.format(
				'\t{ "%s", "%s", %d, %d },' ,
				m.name:gsub(".", CEscapes),
				m.chunkname:gsub(".", CEscapes),
				m.off,
				m.len
			)
			-- Extra names for the same code (X/init.lua is both "X" and
			-- "X.init" through package.path). Extra rows over the same blob:
			-- the payload is embedded once, only the name lookup grows.
			for _, alias in ipairs(m.aliases or {}) do
				modEntries[#modEntries + 1] = string.format(
					'\t{ "%s", "%s", %d, %d },',
					alias:gsub(".", CEscapes),
					("@" .. alias):gsub(".", CEscapes),
					m.off,
					m.len
				)
			end
		end

		loaderHelper = string.format([[
static const struct lde_module { const char* name; const char* chunkname; size_t off; size_t len; } lde_modules[] = {
%s
};

static int lde_module_loader(lua_State* L) {
	const char* name = lua_tostring(L, 1);
	for (size_t i = 0; i < sizeof(lde_modules) / sizeof(lde_modules[0]); i++) {
		if (strcmp(name, lde_modules[i].name) == 0) {
			if (luaL_loadbuffer(L, (const char*)lde_bundle_start + lde_modules[i].off,
					lde_modules[i].len, lde_modules[i].chunkname) != LUA_OK) {
				return lua_error(L);
			}
			lua_pushvalue(L, 1); /* modules may use (...) at the top level */
			lua_call(L, 1, 1);
			return 1;
		}
	}
	return luaL_error(L, "module '%%s' not found in bundle", name);
}
]], table.concat(modEntries, "\n"))

		local mainMod
		for _, m in ipairs(modules) do
			if m.name == source.name then mainMod = m end
		end
		if not mainMod then
			error("bundle is missing the main module '" .. source.name .. "'")
		end

		for _, m in ipairs(modules) do
			local names = { m.name }
			for _, alias in ipairs(m.aliases or {}) do
				names[#names + 1] = alias
			end
			for _, name in ipairs(names) do
				if name ~= source.name then
					preloadSetup[#preloadSetup + 1] = string.format(
						'lua_pushstring(L, "%s"); lua_pushcfunction(L, lde_module_loader); lua_settable(L, -3);',
						name:gsub(".", CEscapes)
					)
				end
			end
		end

		mainLoad = string.format(
			'luaL_loadbuffer(L, (const char*)lde_bundle_start + %d, %d, "%s"); lua_setfield(L, -2, "%s");',
			mainMod.off, mainMod.len,
			mainMod.chunkname:gsub(".", CEscapes),
			mainMod.name:gsub(".", CEscapes)
		)
	elseif isBytecode then ---@cast source string
		-- LuaJIT bytecode wrapper (contains the escaped module bytecode as
		-- string constants), linked as a raw blob.
		bundleDecls = writeBundleBlob(source)

		filePreloads = {
			('luaL_loadbuffer(L, (const char*)lde_bundle_start, (size_t)(lde_bundle_end - lde_bundle_start), "@%s"); lua_setfield(L, -2, "%s");')
				:format(main:gsub(".", CEscapes), main:gsub(".", CEscapes))
		}
	else ---@cast source string
		filePreloads = {
			('luaL_loadbuffer(L, "%s", %d, "@%s"); lua_setfield(L, -2, "%s");')
				:format(
					source:gsub(".", CEscapes),
					#source,
					main:gsub(".", CEscapes),
					main:gsub(".", CEscapes)
				)
		}
	end

	const extraIncludes = {}
	if hasLibs then
		extraIncludes[#extraIncludes + 1] = "#include <stdint.h>\n#include <string.h>\n#include <stdlib.h>\n"
	end
	if isRawBundle then
		-- lde_module_loader uses strcmp/size_t.
		extraIncludes[#extraIncludes + 1] = "#include <string.h>\n#include <stddef.h>\n"
	end
	const stdintInclude = table.concat(extraIncludes) .. "#ifndef _WIN32\n#include <unistd.h>\n#endif\n"

	-- lde_loadlib_loader: a C closure that calls package.loadlib(upvalue1, "*").
	-- Only emitted when there are shared libs to avoid dead-code warnings.
	local loadlibHelper = ""
	if hasLibs then
		loadlibHelper = [[
static int lde_loadlib_loader(lua_State* L) {
	const char* soPath = lua_tostring(L, lua_upvalueindex(1));
	const char* sym    = lua_tostring(L, lua_upvalueindex(2));
	lua_getglobal(L, "package");
	lua_getfield(L, -1, "loadlib");
	lua_pushstring(L, soPath);
	lua_pushstring(L, sym);
	if (lua_pcall(L, 2, 1, 0) != LUA_OK) {
		return luaL_error(L, "loadlib failed for %s: %s", soPath, lua_tostring(L, -1));
	}
	if (lua_type(L, -1) == LUA_TFUNCTION) {
		if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
			return luaL_error(L, "init failed for %s: %s", soPath, lua_tostring(L, -1));
		}
	}
	return 1;
}
]]
	end


	local code = stdintInclude .. [[
#include <stdio.h>
#include "lauxlib.h"
#include "lualib.h"

	]] .. libDeclsStr .. bundleDecls .. loaderHelper .. [[

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

	]] .. shimStartup .. [[

	lua_createtable(L, argc, 0);
	for (int i = 0; i < argc; i++) {
		lua_pushstring(L, argv[i]);
		lua_rawseti(L, -2, i);
	}
	lua_setglobal(L, "arg");

	lua_getglobal(L, "package");
	lua_getfield(L, -1, "preload");

	]] .. table.concat(filePreloads, "\n\t") .. table.concat(preloadSetup, "\n\t") .. mainLoad .. [[

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
		fflush(NULL);
#ifdef _WIN32
		return 1;
#else
		_exit(1);
#endif
	}

	/* Skip lua_close: the OS reclaims the Lua state at exit, and lua_close's
	 * GC teardown costs ~0.2ms on every run. Flush stdio explicitly since
	 * _exit bypasses the C runtime's atexit flushing. */
	fflush(NULL);
#ifdef _WIN32
	return 0;
#else
	_exit(0);
#endif
}
]]

	return code
end

return emit
