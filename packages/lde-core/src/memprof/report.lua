-- Text report for `lde run --memprof`, and the helpers the HTML memory graph shares with it.

const ansi = require("ansi")

const report = {}

const SPARK_CHARS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
const MAX_CALLERS = 4

---@param bytes number
function report.formatBytes(bytes)
	const abs = math.abs(bytes)
	if abs < 1024 then return string.format("%d B", bytes) end
	if abs < 1024 * 1024 then return string.format("%.1f KiB", bytes / 1024) end
	if abs < 1024 * 1024 * 1024 then return string.format("%.1f MiB", bytes / (1024 * 1024)) end
	return string.format("%.1f GiB", bytes / (1024 * 1024 * 1024))
end

--- Shorten a sampled location: drop the cwd and a package's target/<name>/ prefix. Windows locations use backslashes, and the cwd may use either separator.
---@param loc string
---@param cwd string?
function report.relativize(loc, cwd)
	if cwd and loc:sub(1, #cwd):gsub("\\", "/") == cwd:gsub("\\", "/") then
		const separator = loc:sub(#cwd + 1, #cwd + 1)
		if separator == "/" or separator == "\\" then loc = loc:sub(#cwd + 2) end
	end
	return (loc:gsub("^target[/\\][^/\\]+[/\\]", ""))
end

---@class lde.memprof.Frame
---@field name     string  # function name, "main chunk" or "function"
---@field location string? # file:line running in this frame

--- Split a sampled stack ("fn@/abs/file.lua:12;caller@/abs/file.lua:30") into frames, innermost first. Builtins (pcall, require) are dropped: they only pass calls through.
---@param stack string
---@param cwd string?
---@return lde.memprof.Frame[]
function report.frames(stack, cwd)
	const frames = {}
	for frame in stack:gmatch("[^;]+") do
		local name, location = frame:match("^(.-)@(.+)$")
		if not name then name, location = frame, nil end
		if not (location and location:find("^%[builtin")) then
			-- Without a derivable name LuaJIT writes the function's file:firstline; line 0 is a main chunk.
			if name:find(":%d+$") then name = name:find(":0$") and "main chunk" or "function" end
			frames[#frames + 1] = {
				name = name,
				location = location and report.relativize(location, cwd),
			}
		end
	end
	return frames
end

---@param frame lde.memprof.Frame
function report.frameLabel(frame)
	return frame.location and (frame.name .. " " .. frame.location) or frame.name
end

---@param values number[]
local function sparkline(values)
	local low, high = math.huge, -math.huge
	for _, v in ipairs(values) do
		low = math.min(low, v)
		high = math.max(high, v)
	end
	const parts = {}
	for i, v in ipairs(values) do
		const level = high > low and math.floor((v - low) / (high - low) * (#SPARK_CHARS - 1) + 0.5) or 0
		parts[i] = SPARK_CHARS[level + 1]
	end
	return table.concat(parts)
end

---@param s string
local function wln(s) io.write(s .. "\n") end

---@param mem lde.MemoryProfile
---@param sep string
local function printLeaks(mem, sep)
	io.write("\n")
	if mem.heapError then
		wln(ansi.format("  {red}Heap snapshots failed: %s", mem.heapError))
		return
	end
	const snapshots = mem.snapshots or {}
	if #snapshots < 2 then
		wln(ansi.format("  {gray}Leak suspects: the run was too short for two heap snapshots"))
		return
	end
	const first, last = snapshots[1], snapshots[#snapshots]
	const span = first.label and string.format("%q → %q", first.label, last.label)
		or string.format("%dms → %dms", first.atMs, last.atMs)
	wln(ansi.format("  {bold}Leak suspects{reset} · {gray}%d heap snapshots (%s), reachable %s → %s",
		#snapshots, span, report.formatBytes(first.attributed), report.formatBytes(last.attributed)))
	wln(ansi.colorize("gray", "  what kept growing, by the variable or field that holds it"))
	wln("  " .. sep)
	const leaks = mem.leaks or {}
	if #leaks == 0 then
		wln(ansi.format("  {green}No steadily growing retainers"))
		return
	end
	for i = 1, math.min(#leaks, 10) do
		const leak = leaks[i]
		const color = i == 1 ? "red" : i <= 3 ? "yellow" : "white"
		wln("  "
			.. ansi.colorize(color, string.format("%-10s", "+" .. report.formatBytes(leak.growth)))
			.. "  " .. ansi.colorize("gray", sparkline(leak.series))
			.. "  " .. leak.path
			.. (leak.items > 0 and ansi.colorize("gray", string.format("  +%d items", leak.items)) or ""))
	end
end

---@param mem lde.MemoryProfile
---@param cwd string?
---@param sep string
local function printSites(mem, cwd, sep)
	const sorted = {}
	for stack, bytes in pairs(mem.stacks) do
		sorted[#sorted + 1] = { stack = stack, bytes = bytes }
	end
	table.sort(sorted, |a, b| -> a.bytes > b.bytes)
	if #sorted == 0 then return end

	io.write("\n")
	wln(ansi.format("  {bold}Allocation sites"))
	wln(ansi.colorize("gray", string.format(
		"  memory that grew between %dms samples, charged to the line running at the sample", mem.intervalMs)))
	wln("  " .. sep)
	const indent = string.rep(" ", 20)
	for i = 1, math.min(#sorted, 15) do
		const entry = sorted[i]
		const pct = mem.allocated > 0 and entry.bytes / mem.allocated * 100 or 0
		const color = i == 1 ? "red" : i <= 3 ? "yellow" : "white"
		const frames = report.frames(entry.stack, cwd)
		const top = frames[1] or { name = entry.stack }
		wln("  "
			.. ansi.colorize(color, string.format("%5.1f%%", pct))
			.. "  " .. ansi.colorize("gray", string.format("%-10s", report.formatBytes(entry.bytes)))
			.. "  " .. ansi.format("{bold}%s{reset}", top.name)
			.. (top.location and ansi.colorize("cyan", "  " .. top.location) or ""))
		if #frames > 1 then
			const callers = {}
			for f = 2, math.min(#frames, MAX_CALLERS + 1) do callers[#callers + 1] = report.frameLabel(frames[f]) end
			if #frames > MAX_CALLERS + 1 then callers[#callers + 1] = "…" end
			wln(indent .. ansi.colorize("gray", "← " .. table.concat(callers, " ← ")))
		end
	end
end

---@param mem lde.MemoryProfile
---@param cwd string?
function report.print(mem, cwd)
	const sep = ansi.colorize("gray", string.rep("─", 54))
	io.write("\n")
	wln(ansi.format("  {bold}Memory{reset} · {cyan}%s{reset} retained after exit · {gray}%s peak",
		report.formatBytes(mem.retained or 0), report.formatBytes(mem.peak)))
	wln("  " .. sep)
	wln(ansi.format("  {gray}Sampled growth: %s in total, including garbage that was collected later",
		report.formatBytes(mem.allocated)))
	printLeaks(mem, sep)
	printSites(mem, cwd, sep)
	io.write("\n")
end

return report
