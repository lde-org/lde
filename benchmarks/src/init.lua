local ffi = require("ffi")

local process = require("process")
local ansi = require("ansi")
local fs = require("fs")

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

	local function read(cmd, args)
		local code, stdout = process.exec(cmd, args, { stderr = "null" })
		return code == 0 and stdout and stdout:gsub("%s+$", "") or nil
	end

	local function match(out, pattern)
		return out and out:match(pattern) or nil
	end

	if ffi.os == "Windows" then
		row("OS", read("cmd", { "/c", "ver" }))
		row("CPU Model", match(read("wmic", { "cpu", "get", "Name", "/value" }), "Name=(.+)"))
		row("CPU Cores", match(read("wmic", { "cpu", "get", "NumberOfCores", "/value" }), "NumberOfCores=(.+)"))
		row("Total Memory", match(read("wmic", { "computersystem", "get", "TotalPhysicalMemory", "/value" }), "TotalPhysicalMemory=(.+)"))
		row("Hostname", os.getenv("COMPUTERNAME"))
	else
		row("OS", read("uname", { "-sr" }))
		row("Hostname", read("hostname"))
		---@format disable-next
		row("CPU Model", read("sh", { "-c", "grep -m1 -E 'model name|Processor' /proc/cpuinfo | cut -d: -f2 | xargs" }) or read("sysctl", { "-n", "machdep.cpu.brand_string" }))
		row("CPU Cores", read("sh", { "-c", "nproc 2>/dev/null || sysctl -n hw.logicalcpu" }))

		local meminfo = read("sh", { "-c", "grep MemTotal /proc/meminfo" })
		local memGB = meminfo and meminfo:match("(%d+)") and
			("%d GB"):format(tonumber(meminfo:match("(%d+)")) / 1024 / 1024) or
			read("sh", { "-c", "sysctl -n hw.memsize | awk '{print int($1/1073741824) \" GB\"}'" })
		row("Total Memory", memGB)
		row("Platform", read("uname", { "-m" }))
	end
end

sysinfo()

---@param label string
---@param opts { run: fun(): boolean?, string?, prepare?: fun(), warmup?: integer, runs?: integer }
local function bench(label, opts)
	local p = ansi.progress(label)
	local runs = opts.runs or 1
	local warmup = opts.warmup or 0

	for _ = 1, warmup do
		if opts.prepare then opts.prepare() end
		local ok, err = opts.run()
		if not ok then
			p:fail(label .. " warmup failed: " .. (err or "unknown"))
			return
		end
	end

	local times = {}
	for i = 1, runs do
		if opts.prepare then opts.prepare() end
		local start = now()
		local ok, err = opts.run()
		local elapsed = (now() - start) / 1e9
		if not ok then
			p:fail(label .. " run " .. i .. "/" .. runs .. " failed: " .. (err or "unknown"))
			return
		end
		times[#times + 1] = elapsed
	end

	table.sort(times)

	local sum = 0
	for _, t in ipairs(times) do sum = sum + t end
	local mean = sum / runs

	local mid = math.floor(runs / 2)
	local median = runs % 2 == 1 and times[mid + 1] or (times[mid] + times[mid + 1]) / 2

	local variance = 0
	for _, t in ipairs(times) do variance = variance + (t - mean) * (t - mean) end
	local stddev = math.sqrt(variance / runs)

	local stats = string.format("min: %.3fs  median: %.3fs  mean: %.3fs ± %.3fs  (%d runs)",
		times[1], median, mean, stddev, runs)
	p:done(label .. " " .. ansi.colorize("gray", stats))
end

local shh = { stdout = "null" }

---@param tool string  -- "lde" | "luarocks" | "lx"
---@param tmpdir string
local function runBenchmarks(tool, tmpdir)
	ansi.printf("\n{bold}=== %s ==={reset}", tool)

	local treeDir = tmpdir .. (tool == "lde" and "/lde" or "/rocks")

	-- Run counts match the reference hyperfine benchmark parameters:
	-- cold installs warmup 0 runs 5, warm installs warmup 2 runs 10.
	bench("install busted (cold)", {
		warmup = 0,
		runs = 5,
		prepare = function()
			fs.rmdir(treeDir)
		end,
		run = function()
			local code, _, stderr
			if tool == "lde" then
				code, _, stderr = process.exec("lde", { "--tree", treeDir, "install", "rocks:busted" }, shh)
			elseif tool == "luarocks" then
				code, _, stderr = process.exec("luarocks", { "--tree", treeDir, "install", "busted" }, shh)
			elseif tool == "lx" then
				code, _, stderr = process.exec("lx", { "--tree", treeDir, "install", "busted" }, shh)
			end
			return code == 0, stderr
		end,
	})

	bench("install busted (warm)", {
		warmup = 2,
		runs = 10,
		run = function()
			local code, _, stderr
			if tool == "lde" then
				code, _, stderr = process.exec("lde", { "--tree", treeDir, "install", "rocks:busted" }, shh)
			elseif tool == "luarocks" then
				code, _, stderr = process.exec("luarocks", { "--tree", treeDir, "install", "busted" }, shh)
			elseif tool == "lx" then
				code, _, stderr = process.exec("lx", { "--no-prompt", "--tree", treeDir, "install", "busted" }, shh)
			end
			return code == 0, stderr
		end,
	})

	bench("build C rock (luafilesystem)", {
		warmup = 0,
		runs = 5,
		prepare = function()
			fs.rmdir(treeDir)
		end,
		run = function()
			local code, _, stderr
			if tool == "lde" then
				code, _, stderr = process.exec("lde", { "--tree", treeDir, "install", "rocks:luafilesystem" }, shh)
			elseif tool == "luarocks" then
				code, _, stderr = process.exec("luarocks", { "--tree", treeDir, "install", "luafilesystem" }, shh)
			elseif tool == "lx" then
				code, _, stderr = process.exec("lx", { "--tree", treeDir, "install", "luafilesystem" }, shh)
			end
			return code == 0, stderr
		end,
	})
end

local tools = {}
for _, tool in ipairs({ "lde", "luarocks", "lx" }) do
	local code = process.exec(tool, { "--version" }, { stdout = "null", stderr = "null" })
	if code == 0 then
		tools[#tools + 1] = tool
	end
end

if #tools == 0 then
	ansi.printf("{red}No supported tools found (lde, luarocks, lx){reset}")
	os.exit(1)
end

for _, tool in ipairs(tools) do
	local tmpdir = os.tmpname():gsub("[^/\\]+$", "") .. "bench_" .. tool
	fs.mkdirAll(tmpdir)

	runBenchmarks(tool, tmpdir)

	fs.rmdir(tmpdir)
end
