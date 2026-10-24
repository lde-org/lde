local ffi = require("ffi")

local process = require("process")
local ansi = require("ansi")
local fs = require("fs")

-- Short sleep for the memory sampling loop.
local sleep
if ffi.os == "Windows" then
	ffi.cdef [[ void Sleep(unsigned long ms); ]]
	sleep = function(ms) ffi.C.Sleep(ms) end
else
	ffi.cdef [[ int usleep(unsigned int usec); ]]
	sleep = function(ms) ffi.C.usleep(ms * 1000) end
end

-- How often to sample the tool's RSS while it runs. /proc reads on Linux are
-- cheap (microseconds), so 1ms sampling is fine; macOS and Windows sample via
-- a subprocess (`ps` / PowerShell), which is far heavier, hence longer waits.
---@type integer
local sampleIntervalMs = ffi.os == "Linux" and 1 or (ffi.os == "OSX" and 50 or 250)

-- Sample the peak RSS of a live process so far, in bytes.
---@param pid number
---@return number? # nil when the process is gone or the value can't be read
local function readPeakRSS(pid)
	if ffi.os == "Linux" then
		-- VmHWM is the peak resident set size (high-water mark), in kB.
		local f = io.open("/proc/" .. pid .. "/status")
		if not f then return nil end
		local status = f:read("*a")
		f:close()
		local kb = status:match("VmHWM:%s*(%d+) kB")
		return kb and tonumber(kb) * 1024 or nil
	elseif ffi.os == "OSX" then
		local code, out = process.exec("ps", { "-o", "rss=", "-p", tostring(pid) })
		local kb = code == 0 and out and out:match("(%d+)")
		return kb and tonumber(kb) * 1024 or nil
	else
		-- Windows: PeakWorkingSet64 is the peak working set so far, in bytes.
		local code, out = process.exec("powershell", { "-NoProfile", "-Command",
			"(Get-Process -Id " .. pid .. " -ErrorAction SilentlyContinue).PeakWorkingSet64" })
		local bytes = code == 0 and out and out:match("(%d+)")
		return bytes and tonumber(bytes) or nil
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

---@class bench.Summary
---@field time number # median time in seconds
---@field peak number? # median peak RSS in bytes

---@type string[]  -- benchmark labels, in definition order
local benchLabels = {}
---@type table<string, boolean>
local benchSeen = {}
---@type table<string, table<string, bench.Summary>> -- label -> tool -> medians
local benchResults = {}
---@type string[]  -- tools, in run order
local benchTools = {}

---@param code number?
---@param err string?
local function failureMsg(code, err)
	if err and #err > 0 then return err end
	if code then return "exit code " .. code end
	return "unknown error"
end

--- Child handle shape, declared locally: the `process` class is only reachable
--- through a symlinked target dir here, which the checker cannot resolve.
---@class bench.Child
---@field kill fun(self: bench.Child, force: boolean?)
---@field wait fun(self: bench.Child): number?, string?, string?
---@field poll fun(self: bench.Child): number?

---@class bench.Options
---@field tool string
---@field spawn fun(): bench.Child?, string? # spawn the command to time
---@field prepare fun()?
---@field warmup integer?
---@field runs integer?

---@class bench.Stats
---@field median number
---@field mean number

---@param label string
---@param opts bench.Options
---@return bench.Stats?, bench.Stats? # time stats, peak RSS stats (nil when not measurable)
local function bench(label, opts)
	local p = ansi.progress(label)
	local runs = opts.runs or 1
	local warmup = opts.warmup or 0

	-- Register the label up front so the summary keeps definition order
	-- even when a benchmark fails partway through.
	if not benchSeen[label] then
		benchSeen[label] = true
		benchLabels[#benchLabels + 1] = label
	end

	---@return number?, string?, number? # exit code, stderr, peak RSS bytes
	local function runOnce()
		local child, err = opts.spawn()
		if not child then return nil, err, nil end

		-- Sample RSS until the child exits. VmHWM / PeakWorkingSet64 are
		-- high-water marks, so the max over samples is the true peak.
		local peak, measured = 0, false
		local code
		while true do
			local rss = readPeakRSS(child.pid)
			if rss then
				measured = true
				if rss > peak then peak = rss end
			end
			code = child:poll()
			if code ~= nil then break end
			sleep(sampleIntervalMs)
		end

		-- Drain stderr so a chatty child can't deadlock on a full pipe.
		local _, stderr = child:wait()
		return code, stderr, measured and peak or nil
	end

	for _ = 1, warmup do
		if opts.prepare then opts.prepare() end
		local code, err = runOnce()
		if code ~= 0 then
			p:fail(label .. " warmup failed: " .. failureMsg(code, err))
			return nil, nil
		end
	end

	local times, peaks = {}, {}
	for i = 1, runs do
		if opts.prepare then opts.prepare() end
		local start = ansi.now()
		local code, err, peak = runOnce()
		local elapsed = ansi.now() - start
		if code ~= 0 then
			p:fail(label .. " run " .. i .. "/" .. runs .. " failed: " .. failureMsg(code, err))
			return nil, nil
		end
		times[#times + 1] = elapsed
		if peak then peaks[#peaks + 1] = peak end
	end

	table.sort(times)
	table.sort(peaks)

	---@param values number[]
	---@return bench.Stats
	local function summarize(values)
		local sum = 0
		for _, v in ipairs(values) do sum = sum + v end
		local mean = sum / #values
		local mid = math.floor(#values / 2)
		local median = #values % 2 == 1 and values[mid + 1] or (values[mid] + values[mid + 1]) / 2
		return { median = median, mean = mean }
	end

	local t = summarize(times)
	local variance = 0
	for _, x in ipairs(times) do variance = variance + (x - t.mean) * (x - t.mean) end
	local stddev = math.sqrt(variance / runs)

	local line = string.format("min: %.3fs  median: %.3fs  mean: %.3fs ± %.3fs  (%d runs)",
		times[1], t.median, t.mean, stddev, runs)

	local ps
	if #peaks > 0 then
		ps = summarize(peaks)
		line = line .. string.format("  peak RSS: min %s  median %s  mean %s",
			ansi.formatBytes(peaks[1]), ansi.formatBytes(ps.median), ansi.formatBytes(ps.mean))
	end

	p:done(label .. " " .. ansi.colorize("gray", line))

	benchResults[label] = benchResults[label] or {}
	benchResults[label][opts.tool] = { time = t.median, peak = ps and ps.median }

	return t, ps
end

local function printSummary()
	ansi.printf("\n{bold}=== Summary (median of runs) ==={reset}")

	local short = {
		["install busted (cold)"] = "busted (cold)",
		["install busted (warm)"] = "busted (warm)",
		["build C rock (luafilesystem)"] = "luafilesystem (C)",
	}

	local col = 20
	local header = string.format("%-10s", "")
	for _, label in ipairs(benchLabels) do
		header = header .. string.format("%" .. col .. "s", short[label] or label)
	end
	ansi.printf(header)

	---@param v string?
	local function cell(v)
		return string.format("%" .. col .. "s", v or "n/a")
	end

	for _, tool in ipairs(benchTools) do
		local timeRow = string.format("%-10s", tool)
		local peakRow = string.format("%-10s", "")
		for _, label in ipairs(benchLabels) do
			local r = benchResults[label] and benchResults[label][tool]
			timeRow = timeRow .. cell(r and string.format("%.3fs", r.time))
			peakRow = peakRow .. cell(r and r.peak and ansi.formatBytes(r.peak) or nil)
		end
		print(timeRow)
		print(peakRow)
	end
end

-- stdout silenced, stderr piped so failure messages can be reported.
local shh = { stdout = "null", stderr = "pipe" }

-- Tool commands and how each names a rock for install.
---@class bench.Tool
---@field bin string
---@field rockPrefix string

---@type table<string, bench.Tool>
local TOOLS = {
	lde = { bin = "lde", rockPrefix = "rocks:" },
	luarocks = { bin = "luarocks", rockPrefix = "" },
	lx = { bin = "lx", rockPrefix = "" },
}

---@class bench.Case
---@field label string
---@field rock string
---@field warmup integer
---@field runs integer
---@field isReset boolean? # wipe the tree before warmup/runs
---@field isLxNoPrompt boolean? # lx asks before repeat installs unless passed --no-prompt

-- Run counts match the reference hyperfine benchmark parameters:
-- cold installs warmup 0 runs 5, warm installs warmup 2 runs 10.
---@type bench.Case[]
local CASES = {
	{ label = "install busted (cold)", rock = "busted", warmup = 0, runs = 5, isReset = true },
	{ label = "install busted (warm)", rock = "busted", warmup = 2, runs = 10, isLxNoPrompt = true },
	{ label = "build C rock (luafilesystem)", rock = "luafilesystem", warmup = 0, runs = 5, isReset = true },
}

--- Build the install argv for one tool and case.
---@param tool string
---@param treeDir string
---@param case bench.Case
---@return string[]
local function installArgv(tool, treeDir, case)
	local argv = { "--tree", treeDir, "install", TOOLS[tool].rockPrefix .. case.rock }
	if case.isLxNoPrompt and tool == "lx" then
		table.insert(argv, 1, "--no-prompt")
	end
	return argv
end

---@param tool string  -- "lde" | "luarocks" | "lx"
---@param tmpdir string
local function runBenchmarks(tool, tmpdir)
	ansi.printf("\n{bold}=== %s ==={reset}", tool)

	local treeDir = tmpdir .. (tool == "lde" and "/lde" or "/rocks")
	local bin = TOOLS[tool].bin

	for _, case in ipairs(CASES) do
		---@type fun()?
		local prepare
		if case.isReset then
			prepare = function()
				fs.rmdir(treeDir)
			end
		end

		bench(case.label, {
			tool = tool,
			warmup = case.warmup,
			runs = case.runs,
			prepare = prepare,
			spawn = function()
				return process.spawn(bin, installArgv(tool, treeDir, case), shh)
			end,
		})
	end
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

	benchTools[#benchTools + 1] = tool
	runBenchmarks(tool, tmpdir)

	fs.rmdir(tmpdir)
end

printSummary()
