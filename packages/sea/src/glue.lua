--- Emits the C source of a shared library (`lde compile --shared`): one
--- exported C function per `---@export`, each pushing its arguments onto the
--- Lua stack and pcalling the registered Lua function.
---
--- The classic Lua/C API is used instead of ffi callbacks: lua_pushvalue +
--- lua_pcall is ~2x cheaper per call than entering the VM through an ffi.cast
--- callback, and an owned Lua string (lua_pushstring) is cheaper than the boxed
--- `const char*` cdata a callback would receive.
---
--- The Lua state is created lazily by the first call to any export, which runs
--- the package entry point. Exports register themselves while it runs (lde-core
--- injects `debug.getregistry()["lde.exports"][name] = fn` after each annotated
--- function) and are pinned to stack slots of the init frame (fast path) and to
--- registry refs (re-entrant calls, see lde_depth) afterwards.

const emit = require("sea.emit")
const util = require("util")

const glue = {}

---@class sea.ExportType
---@field c string # C spelling
---@field push string? # C statement pushing argument `%s`; nil for return-only types
---@field pull string? # C expression converting the result at the stack top; nil for void

---@type table<string, sea.ExportType>
const TYPES = {
	void = { c = "void" },
	bool = { c = "bool", push = "lua_pushboolean(L, %s)", pull = "lua_toboolean(L, -1) != 0" },
	i8 = { c = "int8_t", push = "lua_pushinteger(L, %s)", pull = "(int8_t)lua_tointeger(L, -1)" },
	i16 = { c = "int16_t", push = "lua_pushinteger(L, %s)", pull = "(int16_t)lua_tointeger(L, -1)" },
	i32 = { c = "int32_t", push = "lua_pushinteger(L, %s)", pull = "(int32_t)lua_tointeger(L, -1)" },
	i64 = { c = "int64_t", push = "lde_push_i64(L, %s)", pull = "lde_to_i64(L, -1)" },
	u8 = { c = "uint8_t", push = "lua_pushinteger(L, %s)", pull = "(uint8_t)lua_tointeger(L, -1)" },
	u16 = { c = "uint16_t", push = "lua_pushinteger(L, %s)", pull = "(uint16_t)lua_tointeger(L, -1)" },
	u32 = { c = "uint32_t", push = "lua_pushinteger(L, %s)", pull = "(uint32_t)lua_tointeger(L, -1)" },
	u64 = { c = "uint64_t", push = "lde_push_u64(L, %s)", pull = "lde_to_u64(L, -1)" },
	f32 = { c = "float", push = "lua_pushnumber(L, %s)", pull = "(float)lua_tonumber(L, -1)" },
	f64 = { c = "double", push = "lua_pushnumber(L, %s)", pull = "lua_tonumber(L, -1)" },
	string = { c = "const char*", push = "lua_pushstring(L, %s)", pull = "lua_tostring(L, -1)" },
	ptr = { c = "void*", push = "lua_pushlightuserdata(L, %s)", pull = "lde_to_ptr(L, -1)" },
}

---@type table<string, string>
const ALIASES = {
	int8_t = "i8",
	int16_t = "i16",
	int32_t = "i32",
	int64_t = "i64",
	uint8_t = "u8",
	uint16_t = "u16",
	uint32_t = "u32",
	uint64_t = "u64",
	float = "f32",
	double = "f64",
	["void*"] = "ptr",
}

--- Canonical name of an export type, or nil when it is not in the allowed set.
---@param name string
---@return string?
function glue.resolveType(name)
	if TYPES[name] then return name end
	return ALIASES[name]
end

---@class sea.Export
---@field name string # exported C symbol
---@field params string[] # canonical parameter types
---@field ret string # canonical return type ("void" for none)

-- Turns the (hi, lo) halves of a 64-bit integer outside +-2^53 into an exact int64_t/uint64_t cdata.
const BOX_SOURCE = [[
local ffi = require("ffi")
local u64 = ffi.typeof("uint64_t")
local i64 = ffi.typeof("int64_t")
return function(hi, lo, isSigned)
	local v = u64(hi) * 4294967296 + lo
	if isSigned then return i64(v) end
	return v
end]]

const HELPERS_64 = [[
static int lde_box_ref;

static void lde_push_box(lua_State* L, uint64_t v, int isSigned) {
	lua_rawgeti(L, LUA_REGISTRYINDEX, lde_box_ref);
	lua_pushnumber(L, (lua_Number)(uint32_t)(v >> 32));
	lua_pushnumber(L, (lua_Number)(uint32_t)v);
	lua_pushboolean(L, isSigned);
	lua_call(L, 3, 1);
}

static void lde_push_u64(lua_State* L, uint64_t v) {
	if (v <= (UINT64_C(1) << 53)) lua_pushnumber(L, (lua_Number)v);
	else lde_push_box(L, v, 0);
}

static void lde_push_i64(lua_State* L, int64_t v) {
	if (v >= -(INT64_C(1) << 53) && v <= (INT64_C(1) << 53)) lua_pushnumber(L, (lua_Number)v);
	else lde_push_box(L, (uint64_t)v, 1);
}

/* A 64-bit integer cdata's payload is the integer itself. */
static int64_t lde_to_i64(lua_State* L, int idx) {
	if (lua_type(L, idx) == LDE_TCDATA) return *(const int64_t*)lua_topointer(L, idx);
	return (int64_t)lua_tonumber(L, idx);
}

static uint64_t lde_to_u64(lua_State* L, int idx) {
	if (lua_type(L, idx) == LDE_TCDATA) return *(const uint64_t*)lua_topointer(L, idx);
	lua_Number n = lua_tonumber(L, idx);
	return n < 0 ? (uint64_t)(int64_t)n : (uint64_t)n;
}
]]

const HELPER_PTR = [[
/* A pointer cdata's payload is the pointer; lua_topointer returns the payload address. */
static void* lde_to_ptr(lua_State* L, int idx) {
	int t = lua_type(L, idx);
	if (t == LUA_TLIGHTUSERDATA) return lua_touserdata(L, idx);
	if (t == LDE_TCDATA) return *(void* const*)lua_topointer(L, idx);
	return NULL;
}
]]

---@param s string
local function cString(s)
	return '"' .. s:gsub('[\\"]', "\\%0"):gsub("\n", "\\n") .. '"'
end

---@param export sea.Export
---@param index integer # 0-based slot in lde_refs
---@param anchor string? # registry ref variable keeping a returned string alive
local function emitWrapper(export, index, anchor)
	const ret = TYPES[export.ret]
	const decls = {}
	const pushes = {}
	for i, typeName in ipairs(export.params) do
		const arg = "a" .. (i - 1)
		decls[i] = TYPES[typeName].c .. " " .. arg
		pushes[i] = "\t" .. string.format(assert(TYPES[typeName].push, "return-only type as parameter"), arg) .. ";"
	end

	const isVoid = ret.pull == nil
	local result = ""
	if anchor then
		-- The pointer stays valid while the string is referenced: until this export's next call.
		result = "\tconst char* r = lua_tostring(L, -1);\n\tlua_rawseti(L, LUA_REGISTRYINDEX, " .. anchor .. ");"
	elseif not isVoid then
		result = "\t" .. ret.c .. " r = " .. ret.pull .. ";"
	end

	return table.concat({
		"LDE_API " .. ret.c .. " " .. export.name .. "(" .. (#decls > 0 and table.concat(decls, ", ") or "void") .. ") {",
		"\tlua_State* L = LDE_LIKELY(lde_L != NULL) ? lde_L : lde_boot();",
		"\tint top = lua_gettop(L);",
		string.format("\tint errfunc = lde_prepare(L, %d, %d);", index, #export.params),
		table.concat(pushes, "\n"),
		"\tlde_depth++;",
		string.format("\tif (lua_pcall(L, %d, %d, errfunc) != 0) lde_panic(L, %s);",
			#export.params, isVoid and 0 or 1, cString(export.name)),
		"\tlde_depth--;",
		result,
		"\tlua_settop(L, top);",
		isVoid and "}" or "\treturn r;\n}",
	}, "\n")
end

---@param main string # entry module name
---@param source string|{ name: string, modules: { name: string, code: string }[] } # see emit.buildParts
---@param sharedLibs { name: string, content: string }[]
---@param platform string # "linux" | "windows" | "macos" | "freebsd"
---@param exports sea.Export[]
function glue.buildSource(main, source, sharedLibs, platform, exports)
	-- Two lde libraries in one host (two plugins) each resolve their bundled
	-- native modules against their own LuaJIT, so they must not share a copy.
	const bundled = { main }
	if type(source) == "table" then
		for _, m in ipairs(source.modules) do bundled[#bundled + 1] = m.code end
	else
		bundled[#bundled + 1] = source
	end
	-- Sorted: the bundle lists modules in no fixed order, and a rebuild of the same code should reuse its files.
	table.sort(bundled)
	const parts = emit.buildParts(main, source, sharedLibs, platform, util.hash(table.concat(bundled)))

	local uses64, usesPtr, maxParams = false, false, 0
	const anchorDecls, anchorInit, wrappers, names = {}, {}, {}, {}
	for i, export in ipairs(exports) do
		for _, typeName in ipairs(export.params) do
			uses64 = uses64 or typeName == "i64" or typeName == "u64"
		end
		uses64 = uses64 or export.ret == "i64" or export.ret == "u64"
		usesPtr = usesPtr or export.ret == "ptr"
		maxParams = math.max(maxParams, #export.params)

		local anchor
		if export.ret == "string" then
			anchor = "lde_anchor_" .. i
			anchorDecls[#anchorDecls + 1] = "static int " .. anchor .. ";"
			anchorInit[#anchorInit + 1] = "\tlua_pushboolean(L, 0);\n\t" .. anchor .. " = luaL_ref(L, LUA_REGISTRYINDEX);"
		end

		wrappers[i] = emitWrapper(export, i - 1, anchor)
		names[i] = "\t" .. cString(export.name) .. ","
	end

	local boxInit = ""
	if uses64 then
		boxInit = "\tif (luaL_loadstring(L, " .. cString(BOX_SOURCE) .. ") != 0) return 1;\n"
			.. "\tlua_call(L, 0, 1);\n"
			.. "\tlde_box_ref = luaL_ref(L, LUA_REGISTRYINDEX);"
	end

	return parts.includes .. [[
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include "lauxlib.h"
#include "lualib.h"

#ifdef _WIN32
#define LDE_API __declspec(dllexport)
#else
#define LDE_API __attribute__((visibility("default")))
#endif
#define LDE_LIKELY(x) __builtin_expect(!!(x), 1)
/* lua_type() of a cdata in LuaJIT. */
#define LDE_TCDATA 10

	]] .. parts.decls .. [[

static lua_State* lde_L;
static int lde_isBooted;
/* Exports currently running. At 0 the stack is the init frame, holding the
 * traceback at slot 1 and export i at slot 2 + i. Above 0 an export was
 * re-entered from Lua (Lua -> FFI -> C -> export): absolute indexes now point
 * into that Lua frame, so the slow path goes through registry refs. */
static int lde_depth;
static int lde_traceback_ref;
static int lde_refs[]] .. #exports .. [[];
]] .. table.concat(anchorDecls, "\n") .. "\n" .. (uses64 and HELPERS_64 or "") .. (usesPtr and HELPER_PTR or "") .. [[

static const char* const lde_export_names[] = {
]] .. table.concat(names, "\n") .. [[

};

static int lde_traceback(lua_State* L) {
	const char* msg = lua_tostring(L, 1);
	luaL_traceback(L, L, msg ? msg : "(error object is not a string)", 1);
	return 1;
}

/* Like a Rust panic crossing extern "C": a Lua error cannot unwind through the
 * caller's C frames, and returning a made-up value would hide the bug. */
__attribute__((noreturn)) static void lde_panic(lua_State* L, const char* name) {
	fprintf(stderr, "lde: panic in exported function '%s': %s\n", name, lua_tostring(L, -1));
	fflush(stderr);
	abort();
}

/* Pushes the error handler (when not already at slot 1) and the export's function; returns the handler index. */
static inline int lde_prepare(lua_State* L, int index, int nargs) {
	if (LDE_LIKELY(lde_depth == 0)) {
		lua_pushvalue(L, 2 + index);
		return 1;
	}
	lua_checkstack(L, nargs + 6);
	int errfunc = lua_gettop(L) + 1;
	lua_rawgeti(L, LUA_REGISTRYINDEX, lde_traceback_ref);
	lua_rawgeti(L, LUA_REGISTRYINDEX, lde_refs[index]);
	return errfunc;
}

static int lde_init(void) {
]] .. parts.startup .. [[

	lua_State* L = luaL_newstate();
	if (L == NULL) {
		fprintf(stderr, "lde: panic while initializing: could not create the Lua state\n");
		return 1;
	}
	luaL_openlibs(L);

	]] .. parts.shim .. [[

	lua_settop(L, 0);
	lua_pushcfunction(L, lde_traceback);
	lde_traceback_ref = luaL_ref(L, LUA_REGISTRYINDEX);
	lua_pushcfunction(L, lde_traceback);

	lua_newtable(L);
	lua_setfield(L, LUA_REGISTRYINDEX, "lde.exports");
]] .. boxInit .. "\n" .. table.concat(anchorInit, "\n") .. [[

	lua_createtable(L, 0, 0);
	lua_pushstring(L, "]] .. parts.main .. [[");
	lua_rawseti(L, -2, 0);
	lua_setglobal(L, "arg");

	lua_getglobal(L, "package");
	lua_getfield(L, -1, "preload");

	]] .. parts.preloads .. [[

	lua_getfield(L, -1, "]] .. parts.main .. [[");
	if (lua_pcall(L, 0, 0, 1) != 0) {
		fprintf(stderr, "lde: panic while initializing: %s\n", lua_tostring(L, -1));
		return 1;
	}

	lua_settop(L, 1);
	for (int i = 0; i < ]] .. #exports .. [[; i++) lua_pushnil(L);
	lua_getfield(L, LUA_REGISTRYINDEX, "lde.exports");
	for (int i = 0; i < ]] .. #exports .. [[; i++) {
		lua_getfield(L, -1, lde_export_names[i]);
		if (lua_type(L, -1) != LUA_TFUNCTION) {
			fprintf(stderr, "lde: panic while initializing: export '%s' was never registered: the module defining it must be required by the entry point\n", lde_export_names[i]);
			return 1;
		}
		lua_pushvalue(L, -1);
		lde_refs[i] = luaL_ref(L, LUA_REGISTRYINDEX);
		lua_replace(L, 2 + i);
	}
	lua_pop(L, 1);
	/* Room for the fast path: function, arguments and the 64-bit boxing call. */
	lua_checkstack(L, ]] .. (maxParams + 6) .. [[);

	lde_L = L;
	return 0;
}

/* Runs once, on the first call to any export. */
static lua_State* lde_boot(void) {
	if (lde_isBooted) {
		fprintf(stderr, "lde: panic: an exported function was called while the library was still initializing\n");
		fflush(stderr);
		abort();
	}
	lde_isBooted = 1;
	if (lde_init() != 0) {
		fflush(stderr);
		abort();
	}
	return lde_L;
}

]] .. table.concat(wrappers, "\n\n") .. "\n"
end

return glue
