-- crater/src/packages.lua
--
-- Crater corpus and policy: which LuaRocks packages the shotgun installs,
-- which are bound to another runtime, which installs are expected to fail on
-- this box, and which materialized modules are not plain libraries. Pure data;
-- no I/O and no orchestration.
--
-- Package set (scraped 2026-08-03): the top 100 rocks by all-time downloads
-- from https://luarocks.org/modules (134 pages; see scrape_luarocks.py), plus
-- a tail of well-known standalone libraries ("bN" ranks) and cmake-built
-- bindings ("cN" ranks) for extra coverage.
-- Rocks that are bound to another runtime carry an `engine` field and are
-- recorded as skipped, never installed:
--   * openresty / kong -- need the `ngx` global or OpenResty C symbols
--   * neovim           -- need the `vim` global (nvim host)
--   * lua53            -- pin `lua ~> 5.3`, not LuaJIT
-- (lua-resty-* rocks whose modules load fine standalone *are* still tested:
-- lua-resty-openssl, lua-resty-jit-uuid, lua-resty-string, lua-resty-template.)
--
-- Modules that are not plain libraries are excluded from the require test:
--   * pl.strict                              -- installing global strict mode is
--                                               its whole purpose; requiring it
--                                               breaks every later module
--   * luacheck.main                          -- CLI entry point; unconditionally
--                                               runs main() (and os.exit) when
--                                               required
--   * luacheck.vendor.sha1.bit32_ops         -- implementation-selected: needs
--                                               undeclared 'bit32', and LuaJIT
--                                               picks bit_ops instead
-- rank: all-time download rank (1-100) or "bN" for extra standalone libs.
-- downloads: all-time download count from the scrape ("n/a" for bN extras).
-- engine:  another runtime this rock is bound to; recorded as skipped, never
--          installed (see ENGINE_REASON below).
-- shims:   globals to preload as deep-stub shims before requiring modules
--          ("vim" for neovim-only rocks).
-- extra:   extra luarocks deps the published rockspec forgets to declare.
local PACKAGES = {
	-- ── Top 100: all-time downloads (scraped 2026-08-03 from /modules) ──────
	{ rank = 1,   name = "lua-cjson", downloads = 24120863, skip = { "tests" } },
	{ rank = 2,   name = "luafilesystem", downloads = 15020930, skip = { "tests" } }, -- rock ships its own test suite as a requireable module
	{ rank = 3,   name = "lua-resty-http", downloads = 9881459, engine = "openresty" },
	{ rank = 4,   name = "lua-resty-jwt", downloads = 8776449, engine = "openresty" },
	{ rank = 5,   name = "luasocket", downloads = 7894630 },
	{ rank = 6,   name = "dkjson", downloads = 7829644 },
	{ rank = 7,   name = "argparse", downloads = 7827575 },
	{ rank = 8,   name = "penlight", downloads = 7795023, skip = { "tests" } },
	{ rank = 9,   name = "say", downloads = 7344187 },
	{ rank = 10,  name = "luassert", downloads = 7302873 },
	{ rank = 11,  name = "busted", downloads = 6986954, skip = { "tests" } },
	{ rank = 12,  name = "lua-term", downloads = 6884205 },
	{ rank = 13,  name = "lua_cliargs", downloads = 6772184 },
	{ rank = 14,  name = "luasystem", downloads = 6742362 },
	{ rank = 15,  name = "mediator_lua", downloads = 6659451 },
	{ rank = 16,  name = "luacheck", downloads = 6632287 },
	{ rank = 17,  name = "luasql-mysql", downloads = 6438667 },
	{ rank = 18,  name = "luasec", downloads = 5536125 },
	{ rank = 19,  name = "lpeg", downloads = 5531667 },
	{ rank = 20,  name = "lua-circuit-breaker", downloads = 5478289 },
	{ rank = 21,  name = "kong-circuit-breaker", downloads = 5439887, engine = "kong" },
	{ rank = 22,  name = "config-by-env", downloads = 5117185, engine = "kong" },
	{ rank = 23,  name = "host-interpolate-by-header", downloads = 4474999, engine = "kong" },
	{ rank = 24,  name = "kong-advanced-router", downloads = 4248115, engine = "kong" },
	{ rank = 25,  name = "lua-resty-openssl", downloads = 4101923 }, -- FFI libssl binding, loads standalone
	{ rank = 26,  name = "nginx-lua-prometheus", downloads = 3389139, engine = "openresty" },
	{ rank = 27,  name = "luaossl", downloads = 3158736 },
	{ rank = 28,  name = "lua-resty-session", downloads = 3069899, engine = "openresty" },
	{ rank = 29,  name = "luacov", downloads = 3068737 },
	{ rank = 30,  name = "lua-geoip", downloads = 3066653 },
	{ rank = 31,  name = "inspect", downloads = 2828682 },
	{ rank = 32,  name = "lua-resty-jit-uuid", downloads = 2768453 },
	{ rank = 33,  name = "lua-resty-openidc", downloads = 2747211, engine = "openresty" },
	{ rank = 34,  name = "lua-ffi-zlib", downloads = 2725400 },
	{ rank = 35,  name = "lua-resty-redis-connector", downloads = 2596903, engine = "openresty" },
	{ rank = 36,  name = "bit32", downloads = 2456694 },
	{ rank = 37,  name = "lua-resty-mlcache", downloads = 2298044, engine = "openresty" },
	{ rank = 38,  name = "ldoc", downloads = 2262969, skip = { "tests" } },
	{ rank = 39,  name = "markdown", downloads = 2236070 },
	{ rank = 40,  name = "lua-resty-cookie", downloads = 2145667, engine = "openresty" },
	{ rank = 41,  name = "lua-protobuf", downloads = 2074605 },
	{ rank = 42,  name = "luarocks-build-treesitter-parser", downloads = 2031749 },
	{ rank = 43,  name = "net-url", downloads = 1960980 },
	{ rank = 44,  name = "lua-llthreads2", downloads = 1946897 },
	{ rank = 45,  name = "lua-resty-string", downloads = 1802858 }, -- resty.* FFI/OpenSSL modules, load standalone
	{ rank = 46,  name = "ngx_lua_datadog", downloads = 1730161, engine = "openresty" },
	{ rank = 47,  name = "mpack", downloads = 1729904 },
	{ rank = 48,  name = "basexx", downloads = 1696572 },
	{ rank = 49,  name = "binaryheap", downloads = 1634824 },
	{ rank = 50,  name = "enapter-ucm", downloads = 1632807, engine = "lua53" },
	{ rank = 51,  name = "lua-resty-template", downloads = 1538141 }, -- template engine, loads standalone
	{ rank = 52,  name = "coxpcall", downloads = 1516807 },
	{ rank = 53,  name = "lua-resty-ipmatcher", downloads = 1494789, engine = "openresty" },
	{ rank = 54,  name = "lua-resty-timer", downloads = 1444180, engine = "openresty" },
	{ rank = 55,  name = "uuid", downloads = 1379778 },
	{ rank = 56,  name = "lualogging", downloads = 1375321 },
	{ rank = 57,  name = "luautf8", downloads = 1358157 },
	{ rank = 58,  name = "lua-resty-redis", downloads = 1350897, engine = "openresty" },
	{ rank = 59,  name = "luaipc", downloads = 1285359 },
	{ rank = 60,  name = "http", downloads = 1262224, extra = { "lzlib" } },
	{ rank = 61,  name = "compat53", downloads = 1237866 },
	{ rank = 62,  name = "busted-hjtest", downloads = 1235105, extra = { "busted" }, skip = { "tests" } }, -- busted dep ships its own tests/ dir
	{ rank = 63,  name = "date", downloads = 1216436 },
	{ rank = 64,  name = "luaposix", downloads = 1212206 },
	{ rank = 65,  name = "busted-htest", downloads = 1207224, extra = { "busted" }, skip = { "tests" } }, -- busted dep ships its own tests/ dir
	{ rank = 66,  name = "lyaml", downloads = 1190177 },
	{ rank = 67,  name = "luatz", downloads = 1183209 },
	{ rank = 68,  name = "lrexlib-pcre", downloads = 1168658 },
	{ rank = 69,  name = "base64", downloads = 1141807 },
	{ rank = 70,  name = "luaxxhash", downloads = 1134650 },
	{ rank = 71,  name = "redis-lua", downloads = 1097970 },
	{ rank = 72,  name = "luacrypto", downloads = 1095616 },
	{ rank = 73,  name = "ansicolors", downloads = 1077516 },
	{ rank = 74,  name = "cqueues", downloads = 1076993 },
	{ rank = 75,  name = "nvim-client", downloads = 1068473, engine = "neovim" },
	{ rank = 76,  name = "lua-resty-worker-events", downloads = 1049992, engine = "openresty" },
	{ rank = 77,  name = "lua_pack", downloads = 1037385 },
	{ rank = 78,  name = "pgmoon", downloads = 1014653, extra = { "luasocket" } },
	{ rank = 79,  name = "fifo", downloads = 1001065 },
	{ rank = 80,  name = "lrandom", downloads = 993798 },
	{ rank = 81,  name = "multipart", downloads = 986204 },
	{ rank = 82,  name = "etlua", downloads = 978304 },
	{ rank = 83,  name = "loadkit", downloads = 972898 },
	{ rank = 84,  name = "kong-slack-hmac", downloads = 965311, engine = "kong" },
	{ rank = 85,  name = "lua-messagepack", downloads = 907976 },
	{ rank = 86,  name = "lua-resty-expr", downloads = 890691, engine = "openresty" },
	{ rank = 87,  name = "version", downloads = 878403 },
	{ rank = 88,  name = "lua-resty-upload", downloads = 854111, engine = "openresty" },
	{ rank = 89,  name = "lua-resty-iputils", downloads = 832555, engine = "openresty" },
	{ rank = 90,  name = "luasyslog", downloads = 832218 },
	{ rank = 91,  name = "lua_system_constants", downloads = 831094 },
	{ rank = 92,  name = "lbase64", downloads = 825703 },
	{ rank = 93,  name = "xml2lua", downloads = 824948 },
	{ rank = 94,  name = "lua-resty-healthcheck", downloads = 823651, engine = "openresty" },
	{ rank = 95,  name = "luaexpat", downloads = 821481 },
	{ rank = 96,  name = "kong-lapis", downloads = 814797, engine = "kong" },
	{ rank = 97,  name = "lua-resty-dns-client", downloads = 790832, engine = "openresty" },
	{ rank = 98,  name = "lua-resty-kafka", downloads = 775857, engine = "openresty" },
	{ rank = 99,  name = "datafile", downloads = 749196 },
	{ rank = 100, name = "luaunit", downloads = 738259, skip = { "doc" } },

	-- ── Extras: well-known standalone libraries beyond the top 100 ───────────
	{ rank = "b1",  name = "middleclass", downloads = "n/a" },
	{ rank = "b2",  name = "lume", downloads = "n/a" },
	{ rank = "b3",  name = "serpent", downloads = "n/a", skip = { "t" } },
	{ rank = "b4",  name = "lunajson", downloads = "n/a" },
	{ rank = "b5",  name = "tl", downloads = "n/a" },
	{ rank = "b6",  name = "30log", downloads = "n/a" },
	{ rank = "b7",  name = "i18n", downloads = "n/a" },
	{ rank = "b8",  name = "lpeg_patterns", downloads = "n/a" },
	{ rank = "b9",  name = "underscore", downloads = "n/a" },
	{ rank = "b10", name = "lub", downloads = "n/a", skip = { "tests" } },
	{ rank = "b11", name = "lua-path", downloads = "n/a", skip = { "examples", "test", "tests", "doc" },
		extra = { "luafilesystem" } }, -- path.lfs.fs backend; rockspec forgets it
	{ rank = "b12", name = "lrexlib-posix", downloads = "n/a" },
	{ rank = "b13", name = "json.lua", downloads = "n/a" },
	{ rank = "b14", name = "push", downloads = "n/a" },
	{ rank = "b15", name = "vusted", downloads = "n/a", shims = { "vim" }, skip = { "tests" } },

	-- ── CMake: rocks whose rockspecs use the cmake build backend ─────────────
	{ rank = "c1", name = "rapidjson", downloads = "n/a" }, -- C++ JSON binding
	{ rank = "c2", name = "luv", downloads = "n/a" }, -- libuv bindings
}

--- Rocks whose install requires system libraries (or a working upstream host)
--- that this box can't provide. lde installs them fine once the dependency is
--- present; these are recorded as skipped, not failed.
local EXPECTED_FAIL = {
	["luasql-mysql"] = "needs mysql.h (libmysqlclient-devel)",
	["lua-geoip"] = "needs GeoIP.h (geoip-devel)",
	["lrexlib-pcre"] = "needs pcre.h (pcre-devel); only pcre2 present",
	["luaipc"] = "rock bug: NAME_MAX undefined on modern glibc",
	["luacrypto"] = "does not compile against OpenSSL 3 (2010-era rock)",
	-- Layout limitation, not a rock problem: the dependency's build directory is
	-- `target/<alias>`, so a rock whose *name* contains a dot (`json.lua`) shadows
	-- its own module file `<module>.lua` in the flat target tree.
	["json.lua"] = "rock name contains a dot and collides with its module path",
}

--- Why a rock is skipped without an install attempt: it is bound to a runtime
--- other than standalone LuaJIT (see the `engine` field in PACKAGES).
local ENGINE_REASON = {
	openresty = "OpenResty-only: needs the `ngx` global / OpenResty C symbols",
	kong      = "Kong plugin: only runs inside Kong (OpenResty)",
	neovim    = "neovim-only: needs the `vim` global (nvim host)",
	lua53     = "pins Lua 5.3 (`lua ~> 5.3`), not LuaJIT",
}

--- Modules that are not plain libraries; excluded from the require test.
local EXCLUDE_MODULES = {
	["pl.strict"] = true, -- enabling global strict mode is its whole purpose
	["luacheck.main"] = true, -- CLI entry; runs main() + os.exit when required
	["luacheck.vendor.sha1.bit32_ops"] = true, -- impl-selected; needs undeclared bit32
	["luarocks.build.treesitter-parser"] = true, -- LuaRocks build backend; requires luarocks.fs/dir/path/util which only exist in the build sandbox
	["resty.openssl.auxiliary.nginx_c"] = true, -- C side of the nginx aux module, compiled into OpenResty (references ngx_* C symbols)
	["resty.openssl.auxiliary.nginx"] = true, -- requires the global `ngx`; OpenResty-only
	["resty.openssl.ssl"] = true, -- hard-requires resty.openssl.auxiliary.nginx
	["resty.openssl.ssl_ctx"] = true, -- hard-requires resty.openssl.auxiliary.nginx
	["path.win32.alien.fs"] = true, -- lua-path Windows FFI backend; needs the alien rock on Windows only
	["path.win32.alien.types"] = true, -- lua-path Windows FFI backend; needs alien
	["path.win32.alien.utils"] = true, -- lua-path Windows FFI backend; needs alien
	["path.win32.alien.wcs"] = true, -- lua-path Windows FFI backend; needs alien
	["path.syscall.fs"] = true, -- needs the undeclared ljsyscall rock
	["lub.Param"] = true, -- requires the ancient yaml rock which doesn't compile on LuaJIT (luaL_getn)
	["logging.nginx"] = true, -- lualogging's nginx handler: hard-requires a real OpenResty logger
	["resty.aes"] = true, -- lua-resty-string: calls EVP_md5() at require time; needs libcrypto loaded via ffi.load (LuaJIT's default namespace is libc/libm only)
}

--- Module name prefixes that are example/test programs rather than libraries.
--- luasocket ships samples/ and test/ via copy_directories; the files open
--- sockets and loop forever when required (e.g. samples.mcsend). json.lua ships
--- bench/ — benchmark scripts that run (and crash) when required.
local EXCLUDE_PREFIXES = { "samples.", "test.", "tests.", "bench." }

--- Functional checks for well-known APIs. Values are Lua expressions over the
--- module value `m`; they are spliced into the generated smoke script. Failures
--- are reported as warnings (FUNCERR), not module ERR.
local EXERCISES = {
	lfs = "type(m.currentdir()) == 'string'",
	cjson = "m.encode({ a = 1 }) == '{\"a\":1}'",
	dkjson = "type(m.encode({ a = 1 })) == 'string'",
	socket = "m.gettime and type(m.gettime()) == 'number'",
	MessagePack = "type(m.pack(1)) == 'string'",
	-- require("pl") loads everything into _G and returns a boolean; exercise the
	-- real entry point instead.
	pl = "assert(type(require('pl.utils').split('a,b', ',')) == 'table')",
	lpeg = "assert(m.match('a', 'a') ~= nil)",
	inspect = "assert(type(m.inspect({})) == 'string')",
	date = "assert(type(m()) == 'table' and type(m():fmt('%Y')) == 'string')",
	-- uuid requires uuid.set_rng() to be configured before use; require-only.
}

return {
	PACKAGES = PACKAGES,
	EXPECTED_FAIL = EXPECTED_FAIL,
	ENGINE_REASON = ENGINE_REASON,
	EXCLUDE_MODULES = EXCLUDE_MODULES,
	EXCLUDE_PREFIXES = EXCLUDE_PREFIXES,
	EXERCISES = EXERCISES,
}
