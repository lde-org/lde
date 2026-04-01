local ffi = require("ffi")

local process = require("process")
local ansi = require("ansi")

---@type fun(): number
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
	ffi.cdef [[
		typedef struct { long tv_sec; long tv_nsec; } timespec;
		int clock_gettime(int clk_id, timespec *tp);
	]]

	now = function()
		local t = ffi.new("timespec")
		ffi.C.clock_gettime(1, t) -- CLOCK_MONOTONIC = 1
		return tonumber(t.tv_sec) * 1e9 + tonumber(t.tv_nsec)
	end
end

local function sysinfo()
	ansi.printf("{bold}System Information{reset}")
	local function row(k, v)
		ansi.printf("  {gray}%s:{reset} %s", k, v or "unknown")
	end

	local function read(cmd)
		local ok, out = process.exec(cmd, nil, { unsafe = true, stderr = "null" })
		return ok and out and out:gsub("%s+$", "") or nil
	end

	if ffi.os == "Windows" then
		row("OS", read("cmd /c ver"))
		row("CPU Model", read("wmic cpu get Name /value"):match("Name=(.+)"))
		row("CPU Cores", read("wmic cpu get NumberOfCores /value"):match("NumberOfCores=(.+)"))
		row("Total Memory", read("wmic computersystem get TotalPhysicalMemory /value"):match("TotalPhysicalMemory=(.+)"))
		row("Hostname", os.getenv("COMPUTERNAME"))
	else
		row("OS", read("uname -sr"))
		row("Hostname", read("hostname"))
		---@format disable-next
		row("CPU Model", read("sh -c \"grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs\"") or read("sysctl -n machdep.cpu.brand_string"))
		row("CPU Cores", read("sh -c \"nproc 2>/dev/null || sysctl -n hw.logicalcpu\""))

		---@format disable-next
		row("Total Memory", ("%d GB"):format(tonumber(read("grep MemTotal /proc/meminfo"):match("(%d+)")) / 1024 / 1024))
		row("Platform", read("uname -m"))
	end
end

sysinfo()

---@type fun(): number
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
	ffi.cdef [[
		typedef struct { long tv_sec; long tv_nsec; } timespec;
		int clock_gettime(int clk_id, timespec *tp);
	]]

	now = function()
		local t = ffi.new("timespec")
		ffi.C.clock_gettime(1, t) -- CLOCK_MONOTONIC = 1
		return tonumber(t.tv_sec) * 1e9 + tonumber(t.tv_nsec)
	end
end

---@param label string
---@param fn fun(): boolean?, string?
local function bench(label, fn)
	local p = ansi.progress(label)
	local start = now()
	local ok, err = fn()
	local elapsed = (now() - start) / 1e9
	local time = ansi.colorize("gray", string.format("%.3fs", elapsed))
	if ok then
		p:done(label .. " " .. time)
	else
		p:fail(label .. " " .. time .. (err and ("\n    " .. ansi.colorize("red", err)) or ""))
	end
end

---@param tool string  -- "lde" | "luarocks" | "lx"
---@param tmpdir string
local function runBenchmarks(tool, tmpdir)
	ansi.printf("\n{bold}=== %s ==={reset}", tool)

	bench("install busted (cold)", function()
		if tool == "lde" then
			return process.exec("lde", { "--tree", tmpdir .. "/lde", "install", "rocks:busted" }, { stdout = "null" })
		elseif tool == "luarocks" then
			return process.exec("luarocks", { "--tree", tmpdir .. "/rocks", "install", "busted" })
		elseif tool == "lx" then
			return process.exec("lx", { "--tree", tmpdir .. "/rocks", "install", "busted" })
		end

		return false
	end)

	bench("install busted (warm)", function()
		if tool == "lde" then
			return process.exec("lde", { "--tree", tmpdir .. "/lde", "install", "rocks:busted" }, { stdout = "null" })
		elseif tool == "luarocks" then
			return process.exec("luarocks", { "--tree", tmpdir .. "/rocks", "install", "busted" })
		elseif tool == "lx" then
			return process.exec("lx", { "--tree", tmpdir .. "/rocks", "install", "--force", "busted" })
		end

		return false
	end)

	bench("build C rock (luafilesystem)", function()
		if tool == "lde" then
			return process.exec("lde", { "--tree", tmpdir .. "/lde", "install", "rocks:luafilesystem" }, { stdout = "null" })
		elseif tool == "luarocks" then
			return process.exec("luarocks", { "--tree", tmpdir .. "/rocks", "install", "luafilesystem" })
		elseif tool == "lx" then
			return process.exec("lx", { "--tree", tmpdir .. "/rocks", "install", "luafilesystem" })
		end

		return false
	end)
end

local tools = {}
for _, tool in ipairs({ "lde", "luarocks", "lx" }) do
	if process.exec(tool, { "--version" }, { stdout = "null", stderr = "null" }) then
		tools[#tools + 1] = tool
	end
end

if #tools == 0 then
	ansi.printf("{red}No supported tools found (lde, luarocks, lx){reset}")
	os.exit(1)
end

for _, tool in ipairs(tools) do
	local tmpdir = os.tmpname():gsub("[^/\\]+$", "") .. "bench_" .. tool
	if jit.os == "Windows" then
		os.execute("mkdir " .. tmpdir)
	else
		os.execute("mkdir -p " .. tmpdir)
	end

	runBenchmarks(tool, tmpdir)

	if jit.os == "Windows" then
		os.execute("rmdir /s /q " .. tmpdir)
	else
		os.execute("rm -rf " .. tmpdir)
	end
end
