local sea = {}

local process = require("process")
local path = require("path")
local env = require("env")
local fs = require("fs")
local jit = require("jit")
local ansi = require("ansi")

local util = require("util")

local curl = util.lazy(|| -> require("curl-sys"))
local Archive = util.lazy(|| -> require("archive"))

local ljDistRepo = "lde-org/luajit"
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

--- Parse arch and libc from a compiler's -dumpmachine output.
--- Returns nil for both if the platform doesn't use a libc triplet component (OSX, Windows).
--- On Linux, derives arch from the triplet so cross-compilers (e.g. Android NDK) work correctly.
---@param compiler string
---@return string|nil arch  -- e.g. "x86-64" or "aarch64"
---@return "musl" | "gnu" | "android" | nil libc
local function getTargetFromCompiler(compiler)
	if jit.os == "OSX" then return nil, nil end
	if jit.os == "Windows" then return nil, "gnu" end

	---@type string?
	local arch

	-- Use the compiler's -dumpmachine to get the target triplet.
	local code, out = process.exec(compiler, { "-dumpmachine" })
	if code == 0 and out and out ~= "" then
		out = out:match("^%s*(.-)%s*$")

		if out:find("^x86_64") or out:find("^x86%-64") then
			arch = "x86-64"
		elseif out:find("^aarch64") then
			arch = "aarch64"
		end

		local libc
		if out:find("android", 1, true) then
			libc = "android"
		elseif out:find("musl", 1, true) then
			libc = "musl"
		elseif out:find("gnu", 1, true) then
			libc = "gnu"
		end

		if arch and libc then
			return arch, libc
		end
	end

	local lddPatterns = { ["musl"] = "musl", ["gnu"] = "GNU libc" }

	local _, lddout = process.exec("ldd", { "--version" })
	for libc, pattern in pairs(lddPatterns) do
		if string.find(lddout or "", pattern, 1, true) then return arch, libc end
	end

	io.stderr:write("[sea] warning: could not detect target from compiler '" .. compiler .. "', defaulting to gnu\n")

	return arch, "gnu"
end

---@param compiler? string
---@return string
local function getLuajitPath(compiler)
	compiler = compiler or env.var("SEA_CC") or "gcc"

	local cacheDir = path.join(env.tmpdir(), "luajit-cache")
	local platform, hostArch = getPlatformArch()
	local compilerArch, libc = getTargetFromCompiler(compiler)
	local arch = compilerArch or hostArch

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

	local bar = ansi.progress("Downloading " .. tarballName)
	local ok, dlErr = curl().download(downloadUrl, tarballPath, {
		progress = function(dltotal, dlnow)
			local ratio = dltotal > 0 and (dlnow / dltotal) or nil
			local info = dltotal > 0
				and (ansi.formatBytes(dlnow) .. " / " .. ansi.formatBytes(dltotal))
				or ansi.formatBytes(dlnow)
			bar:update(ratio, info)
		end
	})
	if not ok then
		bar:fail("Downloading " .. tarballName)
		error("Failed to download LuaJIT from " .. downloadUrl .. ": " .. (dlErr or ""))
	end
	bar:done("Downloaded " .. tarballName)

	local ok, err = Archive().new(tarballPath):extract(cacheDir)
	if not ok then
		print("??", downloadUrl, tarballPath)
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


---Sanitise a library name so it is safe to use as a C identifier.
local function safeIdent(name)
	return string.gsub(name, "[^%w]", "_")
end

---@param main string # name used as the chunk label
---@param source string|{ name: string, modules: { name: string, code: string }[] } # bundled lua: source string, LuaJIT bytecode string, or a raw bytecode table (bundlePackage { raw = true }) — raw tables are linked as a .incbin blob with lazy preload loaders
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
			or "so"
		local libFileName                   = string.format("lde-lib-%s-%s.%s", lib.name, hash, ext)
		ffiShimEntries[#ffiShimEntries + 1] = string.format('["%s"]="%s"', lib.name, libFileName)
		-- alias as libcurl, libcurl.so/libcurl.dylib, and curl
		local leaf                          = lib.name:match("[^.]+$")  -- e.g. "libcurl"
		local bare                          = leaf:match("^lib(.+)$") or leaf -- e.g. "curl"
		ffiShimEntries[#ffiShimEntries + 1] = string.format('["%s"]="%s"', leaf, libFileName)
		if jit.os == "Windows" then
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

	local hasLibs        = #sharedLibs > 0
	local libDeclsStr    = table.concat(libDecls, "\n")
	local libTmpDirInit  = not hasLibs and "" or [[
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
	local libStartupStr  = libTmpDirInit .. table.concat(libStartup, "\n")
	local libPreloadsStr = table.concat(libPreloads, "\n")

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
	local shimSource = ffiShim
	local shimStartup = ""
	if shimSource ~= "" then
		shimStartup = string.format(
			'luaL_loadbuffer(L, "%s", %d, "@shim"); if (lua_pcall(L, 0, 0, 0) != LUA_OK) { fprintf(stderr, "%%s\\n", lua_tostring(L, -1)); return 1; }',
			shimSource:gsub(".", CEscapes),
			#shimSource
		)
	end

	local isRawBundle = type(source) == "table"
	local isBytecode  = not isRawBundle and source:sub(1, 3) == "\27LJ"

	-- Link a raw byte blob into the binary (1:1 size, zero runtime decode).
	-- The path is content-addressed so recompiles of unchanged code reuse the
	-- file; returns the C declarations (asm + externs) for the blob.
	local function writeBundleBlob(content)
		local hash   = util.fnv1a(content)
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
		local blobParts = {}
		local modules   = {}
		local offset    = 0
		for _, m in ipairs(source.modules) do
			modules[#modules + 1] = {
				name      = m.name,
				chunkname = "@" .. m.name,
				off       = offset,
				len       = #m.code
			}
			blobParts[#blobParts + 1] = m.code
			offset = offset + #m.code
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
			if m.name ~= source.name then
				preloadSetup[#preloadSetup + 1] = string.format(
					'lua_pushstring(L, "%s"); lua_pushcfunction(L, lde_module_loader); lua_settable(L, -3);',
					m.name:gsub(".", CEscapes)
				)
			end
		end

		mainLoad = string.format(
			'luaL_loadbuffer(L, (const char*)lde_bundle_start + %d, %d, "%s"); lua_setfield(L, -2, "%s");',
			mainMod.off, mainMod.len,
			mainMod.chunkname:gsub(".", CEscapes),
			mainMod.name:gsub(".", CEscapes)
		)
	elseif isBytecode then
		-- LuaJIT bytecode wrapper (contains the escaped module bytecode as
		-- string constants), linked as a raw blob.
		bundleDecls = writeBundleBlob(source)

		filePreloads = {
			('luaL_loadbuffer(L, (const char*)lde_bundle_start, (size_t)(lde_bundle_end - lde_bundle_start), "@%s"); lua_setfield(L, -2, "%s");')
				:format(main:gsub(".", CEscapes), main:gsub(".", CEscapes))
		}
	else
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

	local extraIncludes = {}
	if hasLibs then
		extraIncludes[#extraIncludes + 1] = "#include <stdint.h>\n#include <string.h>\n#include <stdlib.h>\n"
	end
	if isRawBundle then
		-- lde_module_loader uses strcmp/size_t.
		extraIncludes[#extraIncludes + 1] = "#include <string.h>\n#include <stddef.h>\n"
	end
	local stdintInclude = table.concat(extraIncludes) .. "#ifndef _WIN32\n#include <unistd.h>\n#endif\n"

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

	local ljPath = getLuajitPath()
	local includePath = path.join(ljPath, "include")
	local libPath = path.join(ljPath, "lib")

	local args = {
		"-I" .. includePath,
		"-xc", "-",
		"-o", outPath,
		"-xnone",
	}

	if jit.os == "Windows" then
		-- Wrap libluajit.a in --whole-archive: link in ALL of its object
		-- files, not just the ones lde itself references. Symbols only ever
		-- called by C modules at runtime (e.g. luaJIT_profile_*) must be
		-- physically present in the exe for --export-all-symbols below to
		-- be able to export them.
		args[#args + 1] = "-Wl,--whole-archive"
		args[#args + 1] = path.join(libPath, "libluajit.a")
		args[#args + 1] = "-Wl,--no-whole-archive"
	else
		args[#args + 1] = path.join(libPath, "libluajit.a")
	end

	if jit.os == "Linux" then
		args[#args + 1] = "-lm"
		args[#args + 1] = "-ldl"
		args[#args + 1] = "-Wl,--export-dynamic" -- expose lua symbols for lua dependencies
	elseif jit.os == "OSX" then
		args[#args + 1] = "-Wl,-export_dynamic" -- expose lua symbols for lua dependencies
	elseif jit.os == "Windows" then
		-- Export lua symbols so C modules can resolve them from the process
		-- image (GetModuleHandle(NULL) + GetProcAddress), matching the
		-- --export-dynamic behavior on Linux/macOS.
		args[#args + 1] = "-Wl,--export-all-symbols"
	end
	local execEnv
	if jit.os == "Windows" and compiler ~= "gcc" then
		-- compiler is a full path into mingw/bin; ensure subtools (as.exe etc) are found
		execEnv = { PATH = path.dirname(compiler) .. ";" .. (env.var("PATH") or "") }
	end
	local code, stdout, stderr = process.exec(compiler, args, { stdin = code, env = execEnv })
	if code ~= 0 or string.find(stderr or "", "is not recognized as an internal", 1, true) then
		local err = (stderr and stderr ~= "" and stderr) or (stdout and stdout ~= "" and stdout) or ""
		error("Compilation failed: " .. err)
	end

	return outPath
end

return sea
