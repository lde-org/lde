-- crater/src/init.lua
--
-- Crater: LuaRocks compatibility shotgun for lde. Installs the most-downloaded
-- LuaRocks packages and verifies every module loads under lde's runtime.
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
-- For every package the harness:
--   1. creates a scratch project with `{ "luarocks": "<name>" }` (+ extra deps
--      where the published rockspec forgets a dependency, e.g. busted-hjtest),
--   2. runs `lde install` twice (cold + warm) and times both,
--   3. discovers every Lua/native module lde materialized into target/,
--   4. runs `lde run main.lua`, which `require()`s each discovered module
--      (plus a tiny functional check for a handful of well-known APIs),
--   5. records per-module results and timings into .shotgun/results.csv.
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
--
-- Some packages only load when a host runtime global exists (e.g. neovim's
-- `vim` for vusted); a documented deep-stub shim is preloaded for those so
-- install + module-load compatibility can still be verified.
--
-- Usage:
--   cd crater
--   lde sync
--   lde run
--
-- Env:
--   LDE             lde binary to test (default: "lde" from PATH)
--   LDE_SHOTGUN_DIR scratch directory (default: <cwd>/.shotgun)
--   LDE_ONLY        comma-separated package filter (e.g. LDE_ONLY=busted,luasec)

local fs = require("fs")
local path = require("path")
local process = require("process")
local ansi = require("ansi")

local LDE = os.getenv("LDE") or "lde"
local SCRATCH = os.getenv("LDE_SHOTGUN_DIR") or path.join(os.getenv("PWD") or ".", ".shotgun")
-- Optional filter: only run the given package(s) (comma-separated), e.g. LDE_ONLY=busted,luacheck
local ONLY = {}
for name in (os.getenv("LDE_ONLY") or ""):gmatch("[^,]+") do ONLY[name:match("^%s*(.-)%s*$")] = true end

local INSTALL_TIMEOUT = 600 -- seconds; guarded by GNU timeout(1) when available
local RUN_TIMEOUT = 120

--- Wall-clock nanosecond counter (CLOCK_MONOTONIC on unix).
local ffi = require("ffi")
ffi.cdef [[
	typedef struct { long tv_sec; long tv_nsec; } timespec;
	int clock_gettime(int clk_id, timespec *tp);
]]
local function now()
	local t = ffi.new("timespec")
	ffi.C.clock_gettime(1, t) -- CLOCK_MONOTONIC
	return tonumber(t.tv_sec) * 1e9 + tonumber(t.tv_nsec)
end

local USE_TIMEOUT = process.exec("timeout", { "--version" }, { stdout = "null", stderr = "null" }) == 0

--- Run a command, bounded by timeoutSec when timeout(1) is available.
--- Returns code, stdout, stderr (code = nil on timeout).
---@param bin string
---@param args string[]
---@param opts { cwd?: string, stdout?: "pipe"|"null", stderr?: "pipe"|"null" }?
---@param timeoutSec number
local function timedExec(bin, args, opts, timeoutSec)
	opts = opts or {}
	local code, stdout, stderr
	if USE_TIMEOUT then
		local argv = { tostring(timeoutSec), bin }
		for _, a in ipairs(args) do argv[#argv + 1] = a end
		code, stdout, stderr = process.exec("timeout", argv, opts)
		if code == 124 then return nil, nil, "timed out after " .. timeoutSec .. "s" end
	else
		code, stdout, stderr = process.exec(bin, args, opts)
	end
	return code, stdout, stderr
end

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
	["lyaml"] = "needs libyaml dev headers (YAML_DIR)",
	["luaipc"] = "rock bug: NAME_MAX undefined on modern glibc",
	["luacrypto"] = "does not compile against OpenSSL 3 (2010-era rock)",
	["luaexpat"] = "needs expat.h (expat-devel)",
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
--- sockets and loop forever when required (e.g. samples.mcsend).
local EXCLUDE_PREFIXES = { "samples.", "test." }

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

--- Deep-stub shim for a global that only exists in a specific runtime
--- (e.g. neovim's `vim`). Any read returns a per-key stub table, any write is
--- dropped, and calling it returns nil. Note: LuaJIT strips the metatable when
--- __index returns a table whose own __index is the *same* function (its
--- self-reference guard), so each stub level needs a fresh closure identity.
local function deepStubSource(global)
	return string.format([[
do
	local stubCache = {}
	local function newStub()
		local mt = {
			__index = function(_, k)
				local v = stubCache[k]
				if not v then
					v = newStub()
					stubCache[k] = v
				end
				return v
			end,
			__newindex = function() end,
			__call = function() return nil end,
		}
		return setmetatable({}, mt)
	end
	%s = newStub()
end
]], global)
end

--- Create a fresh smoke project for one package.
---@param dir string
---@param name string
---@param extra string[]?
local function makeProject(dir, name, extra)
	if not fs.isdir(dir) then
		fs.mkdirAll(path.join(dir, "src"))
		fs.write(path.join(dir, "src", "init.lua"), "return {}\n")
		local deps = '"' .. name .. '":{"luarocks":"' .. name .. '"}'
		for _, dep in ipairs(extra or {}) do
			deps = deps .. ',"' .. dep .. '":{"luarocks":"' .. dep .. '"}'
		end
		local config = '{"name":"' .. name .. '-smoke","version":"0.1.0","dependencies":{' .. deps .. '}}'
		fs.write(path.join(dir, "lde.json"), config)
	end
end

--- Version pinned in the lockfile entry for this package (from the .src.rock URL).
---@param lockContent string
---@param name string
---@return string?
local function lockVersion(lockContent, name)
	local url = lockContent:match('"' .. name .. '"%s*:%s*{.-"archive"%s*:%s*"([^"]+)"')
	return url and url:match("%-([%d%.]+%-%d+)%.src%.rock$") or nil
end

--- Discover modules materialized into target/: `a.lua` -> "a", `a/b.lua` -> "a.b",
--- `a/init.lua` -> "a", `a/b.so` -> "a.b". Skips dependency dirs (which hold bin
--- scripts) and the smoke project's own output dir.
---@param targetDir string
---@param exclude table<string, boolean>
---@return string[]
local function discoverModules(targetDir, exclude)
	local seen, mods = {}, {}
	local function add(rel)
		local parts = {}
		for seg in rel:gmatch("[^/]+") do parts[#parts + 1] = seg end
		if #parts == 0 or exclude[parts[1]] then return end
		local name
		local last = parts[#parts]
		if last == "init.lua" then
			name = table.concat(parts, ".", 1, #parts - 1)
			if name == "" then return end
		else
			parts[#parts] = last:gsub("%.lua$", ""):gsub("%.so$", ""):gsub("%.dll$", "")
			name = table.concat(parts, ".")
		end
		if not seen[name] then
			seen[name] = true
			mods[#mods + 1] = name
		end
	end
	for _, glob in ipairs({ "**/*.lua", "**/*.so", "**/*.dll" }) do
		for _, rel in ipairs(fs.scan(targetDir, glob)) do add(rel) end
	end
	table.sort(mods)
	return mods
end

--- Generate the smoke script: shims, then require every module + functional checks.
---@param mods string[]
---@param shims string[]?
---@return string
---@return number excluded  -- number of discovered modules that were skipped
local function makeMainLua(mods, shims)
	local excluded = 0
	local lines = {
		-- LuaJIT's print() doesn't flush on POSIX pipes and os.exit() skips the
		-- stdio flush, which would silently truncate results; force line buffering.
		"io.stdout:setvbuf('line')",
		"io.stderr:setvbuf('line')",
		-- Modules like luacheck.main call os.exit() at require time (CLI entry
		-- point); turn that into a catchable error so one module can't kill the
		-- whole smoke run.
		"local realExit = os.exit",
		"os.exit = function(code) error('module called os.exit(' .. tostring(code) .. ')', 0) end",
		"local failures = 0",
		"local function report(kind, name, extra)",
		"  if kind == \"OK\" then print(\"OK\\t\" .. name) else failures = failures + 1 print(\"ERR\\t\" .. name .. \"\\t\" .. tostring(extra):gsub(\"[\\r\\n]+\", \" \")) end",
		"end",
	}
	for _, g in ipairs(shims or {}) do
		lines[#lines + 1] = deepStubSource(g)
	end

	for _, name in ipairs(mods) do
		if EXCLUDE_MODULES[name] then
			excluded = excluded + 1
		else
			local skippedByPrefix = false
			for _, p in ipairs(EXCLUDE_PREFIXES) do
				if name:sub(1, #p) == p then skippedByPrefix = true break end
			end
			if skippedByPrefix then
				excluded = excluded + 1
			else
				local check = EXERCISES[name]
				if check then
					lines[#lines + 1] = string.format(
						"local ok, m = pcall(require, %q) if ok then local fok, ferr = pcall(function(m) return %s end, m) if fok and ferr then print(\"FUNC\\t%s\") else failures = failures + 1 print(\"FUNCERR\\t%s\\t\" .. tostring(ferr)) end else report(\"ERR\", %q, m) end",
						name, check, name, name, name)
				else
					lines[#lines + 1] = string.format("do local ok, m = pcall(require, %q) if ok then report(\"OK\", %q) else report(\"ERR\", %q, m) end end",
						name, name, name)
				end
			end
		end
	end
	lines[#lines + 1] = "if failures > 0 then realExit(1) end"
	return table.concat(lines, "\n") .. "\n", excluded
end

---@param code number?
---@return string
local function fmtCode(code)
	if code == nil then return "?" end
	return tostring(code)
end

local ldeVersion
do
	local code, stdout = process.exec(LDE, { "--version" }, { stdout = "pipe", stderr = "null" })
	if code ~= 0 then
		ansi.printf("{red}lde binary not found on PATH (set LDE to override){reset}")
		os.exit(1)
	end
	ldeVersion = stdout and stdout:gsub("%s+$", "") or "?"
end

if not fs.isdir(SCRATCH) then fs.mkdirAll(SCRATCH) end

ansi.printf("{bold}LuaRocks shotgun test{reset}  lde=%s  scratch=%s  timeout(1)=%s",
	ldeVersion, SCRATCH, USE_TIMEOUT and "yes" or "no")

local results = {}
for _, pkg in ipairs(PACKAGES) do
	if next(ONLY) and not ONLY[pkg.name] then goto skip end
	local name = pkg.name
	local dir = path.join(SCRATCH, name)
	local targetDir = path.join(dir, "target")

	ansi.printf("\n[{bold}%s{reset}] {bold}%s{reset}  (%s downloads%s)",
		pkg.rank, name, tostring(pkg.downloads),
		(pkg.shims and #pkg.shims > 0) and ("; shim: " .. table.concat(pkg.shims, ",")) or "")

	if pkg.engine then
		local why = ENGINE_REASON[pkg.engine] or ("bound to " .. pkg.engine)
		ansi.printf("  {gray}skipped: %s{reset}", why)
		results[#results + 1] = { pkg = name, ok = true, rank = pkg.rank, engine = pkg.engine, skipped = why }
		goto continue
	end

	makeProject(dir, name, pkg.extra)

	-- Cold install (fresh project; archives may be warm in ~/.lde)
	local t0 = now()
	local code, _, err = timedExec(LDE, { "install" }, { cwd = dir, stdout = "pipe", stderr = "pipe" }, INSTALL_TIMEOUT)
	local cold = (now() - t0) / 1e9
	if code ~= 0 then
		local skipReason = EXPECTED_FAIL[name]
		if skipReason then
			ansi.printf("  {yellow}install skipped (%.1fs):{reset} %s", cold, skipReason)
			results[#results + 1] = { pkg = name, ok = true, rank = pkg.rank, skipped = skipReason, cold = cold }
			goto continue
		end
		ansi.printf("  {red}install FAILED (%.1fs, exit %s):{reset} %s", cold, fmtCode(code),
			(err or "unknown error"):gsub("%s+$", ""))
		results[#results + 1] = { pkg = name, ok = false, rank = pkg.rank, reason = "install failed: " .. (err or "") }
		goto continue
	end

	-- Warm install (cached fast path)
	t0 = now()
	code = timedExec(LDE, { "install" }, { cwd = dir, stdout = "null", stderr = "null" }, INSTALL_TIMEOUT)
	local warm = (now() - t0) / 1e9

	local lockContent = fs.read(path.join(dir, "lde.lock")) or ""
	local version = lockVersion(lockContent, name)

	-- The alias dir (target/<name>) may *contain* the module itself (e.g.
	-- busted's module materializes as target/busted/init.lua), so only the
	-- project's own output dir and make-install junk dirs are excluded.
	local exclude = { [name .. "-smoke"] = true, bin = true, lib = true, include = true, share = true, etc = true }
	for _, s in ipairs(pkg.skip or {}) do exclude[s] = true end
	local mods = fs.isdir(targetDir) and discoverModules(targetDir, exclude) or {}

	if #mods == 0 then
		ansi.printf("  {yellow}install OK (%.2fs / warm %.3fs) but no modules materialized in target/{reset}", cold, warm)
		results[#results + 1] = { pkg = name, ok = true, rank = pkg.rank, version = version, modules = 0, okModules = 0, cold = cold, warm = warm, run = 0 }
		goto continue
	end

	local mainLua, excluded = makeMainLua(mods, pkg.shims)
	fs.write(path.join(dir, "main.lua"), mainLua)

	t0 = now()
	local rcode, rout = timedExec(LDE, { "run", "main.lua" }, { cwd = dir, stdout = "pipe", stderr = "pipe" }, RUN_TIMEOUT)
	local run = (now() - t0) / 1e9

	local okCount, funcOk, funcErr = 0, 0, 0
	local errors = {}
	for line in (rout or ""):gmatch("[^\r\n]+") do
		local kind, mod, extra = line:match("^(%u+)\t([^\t]+)\t?(.*)$")
		if kind == "OK" then
			okCount = okCount + 1
		elseif kind == "FUNC" then
			funcOk = funcOk + 1
		elseif kind == "FUNCERR" then
			funcErr = funcErr + 1
			errors[#errors + 1] = mod .. ": " .. extra
		elseif kind == "ERR" then
			errors[#errors + 1] = mod .. ": " .. extra
		end
	end

	local tested = #mods - excluded
	local status, reason
	if rcode == nil then
		status, reason = "run timeout", "run timed out"
	elseif #errors > 0 then
		status, reason = "partial", "module failures"
	elseif rcode ~= 0 then
		status, reason = "run failed", "run exited " .. rcode
	elseif okCount + funcOk < tested then
		status, reason = "partial", "missing module output"
	else
		status, reason = "ok", "ok"
	end
	ansi.printf("  install {green}%.2fs{reset} / warm {gray}%.3fs{reset}  run {cyan}%.3fs{reset}  modules %d/%d ok%s",
		cold, warm, run, okCount + funcOk, tested,
		version and ("  (" .. name .. " " .. version .. ")") or "")
	if excluded > 0 then
		ansi.printf("    {gray}(excluded %d non-library module(s)){reset}", excluded)
	end
	if #errors > 0 then
		for i = 1, math.min(#errors, 5) do
			ansi.printf("    {red}%s{reset}", errors[i])
		end
		if #errors > 5 then ansi.printf("    ... and %d more", #errors - 5) end
	end

	results[#results + 1] = {
		pkg = name, ok = status == "ok", reason = reason, rank = pkg.rank, version = version,
		modules = tested, okModules = okCount + funcOk, cold = cold, warm = warm, run = run,
		errors = errors,
	}
	::continue::
	::skip::
end

-- ── Summary ────────────────────────────────────────────────────────────────
local okPkgs, partialPkgs, failedPkgs, skippedPkgs, runtimePkgs = 0, 0, 0, 0, 0
for _, r in ipairs(results) do
	if r.engine then runtimePkgs = runtimePkgs + 1
	elseif r.skipped then skippedPkgs = skippedPkgs + 1
	elseif r.ok then okPkgs = okPkgs + 1
	elseif r.okModules and r.okModules > 0 then partialPkgs = partialPkgs + 1
	else failedPkgs = failedPkgs + 1 end
end

ansi.printf("\n{bold}=== Summary ==={reset}")
ansi.printf("{green}%d{reset} fully working, {yellow}%d{reset} partial, {red}%d{reset} failed, {gray}%d{reset} skipped (needs system lib), {gray}%d{reset} other-runtime  (of %d packages)",
	okPkgs, partialPkgs, failedPkgs, skippedPkgs, runtimePkgs, #results)

local csv = {}
csv[#csv + 1] = "rank,name,version,modules,ok_modules,cold_install_s,warm_install_s,run_s,status,first_error"
local function csvField(s)
	if not s then return "" end
	s = s:gsub("[\r\n]+", " ")
	s = s:gsub('"', '""')
	return '"' .. s .. '"'
end
for _, r in ipairs(results) do
	csv[#csv + 1] = table.concat({
		tostring(r.rank or ""), csvField(r.pkg), csvField(r.version or ""), tostring(r.modules or ""), tostring(r.okModules or ""),
		r.cold and string.format("%.3f", r.cold) or "", r.warm and string.format("%.3f", r.warm) or "",
		r.run and string.format("%.3f", r.run) or "", csvField(r.reason or (r.ok and (r.skipped and ("skipped: " .. r.skipped) or "ok") or "fail")),
		csvField(r.errors and r.errors[1] or ""),
	}, ",")
end
local csvPath = path.join(SCRATCH, "results.csv")
fs.write(csvPath, table.concat(csv, "\n") .. "\n")
ansi.printf("\nCSV results written to {cyan}%s{reset}", csvPath)
