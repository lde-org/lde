local ffi = require("ffi")
local ansi = require("ansi")
local json = require("json")

-- ── timer ─────────────────────────────────────────────────────────────────────

local now
if ffi.os == "Windows" then
	ffi.cdef [[
		typedef union { struct { uint32_t lo, hi; }; uint64_t val; } LARGE_INTEGER;
		int QueryPerformanceCounter(LARGE_INTEGER *lpPerformanceCount);
		int QueryPerformanceFrequency(LARGE_INTEGER *lpFrequency);
	]]
	local freq = ffi.new("LARGE_INTEGER")
	ffi.C.QueryPerformanceFrequency(freq)
	local f = tonumber(freq.val)
	now = function()
		local t = ffi.new("LARGE_INTEGER")
		ffi.C.QueryPerformanceCounter(t)
		return tonumber(t.val) * 1e9 / f
	end
else
	ffi.cdef [[ typedef struct { long tv_sec; long tv_nsec; } timespec;
	            int clock_gettime(int clk_id, timespec *tp); ]]
	now = function()
		local t = ffi.new("timespec")
		ffi.C.clock_gettime(1, t)
		return tonumber(t.tv_sec) * 1e9 + tonumber(t.tv_nsec)
	end
end

-- ── bench helper ──────────────────────────────────────────────────────────────

local function bench(label, fn, iters)
	iters = iters or 1000
	-- warmup
	for _ = 1, math.max(1, math.floor(iters / 10)) do fn() end
	local t0 = now()
	for _ = 1, iters do fn() end
	local ns = (now() - t0) / iters
	ansi.printf("  {gray}%-40s{reset} {bold}%8.2f ns/op{reset}  {gray}(%d iters){reset}",
		label, ns, iters)
end

-- ── fixtures ──────────────────────────────────────────────────────────────────

local SMALL = '{"name":"Alice","age":30,"active":true}'

local MEDIUM = json.encode({
	users = (function()
		local t = {}
		for i = 1, 20 do
			t[i] = { id = i, name = "user" .. i, score = i * 1.5, active = i % 2 == 0 }
		end
		return t
	end)()
})

local LARGE = json.encode((function()
	local t = {}
	for i = 1, 500 do
		t[i] = { id = i, name = "item" .. i, value = i * 3.14, tags = { "a", "b", "c" } }
	end
	return t
end)())

local JSON5_SRC = [[{
	// application config
	name: 'myapp',
	version: '1.0.0',
	/* feature flags */
	features: {
		darkMode: true,
		beta: false,
	},
	ports: [8080, 8443,],
}]]

local SMALL_T  = json.decode(SMALL)
local MEDIUM_T = json.decode(MEDIUM)
local LARGE_T  = json.decode(LARGE)
local JSON5_T  = json.decode(JSON5_SRC)

-- ── run ───────────────────────────────────────────────────────────────────────

ansi.printf("\n{bold}json decode{reset}")
bench("small object (~40 B)",    function() json.decode(SMALL)     end, 5000)
bench("medium array (~20 objs)", function() json.decode(MEDIUM)    end, 500)
bench("large array (~500 objs)", function() json.decode(LARGE)     end, 20)
bench("json5 with comments",     function() json.decode(JSON5_SRC) end, 2000)

ansi.printf("\n{bold}json encode{reset}")
bench("small object",            function() json.encode(SMALL_T)  end, 5000)
bench("medium array",            function() json.encode(MEDIUM_T) end, 500)
bench("large array",             function() json.encode(LARGE_T)  end, 20)
bench("json5 round-trip",        function() json.encode(JSON5_T)  end, 2000)

ansi.printf("\n{bold}json round-trip (decode + encode){reset}")
bench("small",  function() json.encode(json.decode(SMALL))  end, 5000)
bench("medium", function() json.encode(json.decode(MEDIUM)) end, 500)
bench("large",  function() json.encode(json.decode(LARGE))  end, 20)

ansi.printf("\n{bold}json decodeDocument only (zero-alloc){reset}")
bench("small",  function() json.decodeDocument(SMALL)  end, 5000)
bench("medium", function() json.decodeDocument(MEDIUM) end, 500)
bench("large",  function() json.decode(LARGE)  end, 20)
