local ansi = require("ansi")
local fs = require("fs")
local json = require("json")

--- Build timings collection and report writer (`lde sync --timings`,
--- `lde compile --timings`). Units record wall-clock spans of the build
--- pipeline — the resolve/download phase, each dependency's build, bundling,
--- the sea link step — and the report renders them as a Gantt-style timeline
--- (parallel builds are stacked lanes) plus a longest-tasks table. The JSON
--- form is the same data, for machines/LLMs.
---
--- Collection is opt-in: `timings.begin()` must be called (the CLI does it
--- when --timings/--json is passed), and every recording helper is a no-op
--- while inactive, so the pipeline pays nothing unless asked.

---@class timings.Unit
---@field name string
---@field kind string # "build" | "download" | "bundle" | "compile"
---@field start number # seconds since collection start (monotonic)
---@field end number?

---@class timings.Handle
---@field unit timings.Unit

---@type timings.Unit[]?
local units = nil
---@type number
local t0 = 0
---@type { command: string?, package: string?, version: string? }
local meta = {}

---@type table<string, string>
local KIND_COLORS = {
	build = "#4c9be8",
	download = "#e8764c",
	bundle = "#b44ce8",
	compile = "#e84c6b",
}

local M = {}

--- Start a collection. Subsequent start()/finish() calls record units until
--- a report is written or begin() is called again.
---@param opts { command: string?, package: string?, version: string? }?
function M.begin(opts)
	units = {}
	t0 = ansi.now()
	meta = opts or {}
end

---@return boolean true while a collection is active
function M.active()
	return units ~= nil
end

--- Stop the active collection and discard its units. The next begin() starts
--- fresh. No-op when no collection is active.
function M.reset()
	units = nil
end

--- Start a unit; pass the returned handle to finish() once the work ends.
---@param name string
---@param kind string
---@return timings.Handle?
function M.start(name, kind)
	if not units then return nil end
	local unit = { name = name, kind = kind, start = ansi.now() - t0, ["end"] = nil }
	units[#units + 1] = unit
	return { unit = unit }
end

--- Close a unit (records its end time). No-op when inactive or already closed.
---@param handle timings.Handle?
function M.finish(handle)
	if not handle or handle.unit["end"] ~= nil then return end
	handle.unit["end"] = ansi.now() - t0
end

--- Maximum number of units whose [start, end) intervals overlap at any instant
--- — i.e. the peak parallelism of the build.
---@param unitsList { start: number, end: number }[]
---@return integer
local function maxParallelism(unitsList)
	local events = {}
	for _, u in ipairs(unitsList) do
		events[#events + 1] = { t = u.start, delta = 1 }
		events[#events + 1] = { t = u["end"], delta = -1 }
	end
	table.sort(events, function(a, b)
		if a.t ~= b.t then return a.t < b.t end
		-- Starts before ends at the same instant so a boundary overlap counts.
		return a.delta > b.delta
	end)
	local current, max = 0, 0
	for _, e in ipairs(events) do
		current += e.delta
		if current > max then max = current end
	end
	return max
end

--- Complete snapshot of the collection as plain data, ready for JSON.
---@return { version: integer, ldeVersion: string?, command: string?, package: string?, startedAt: string, totalTime: number, maxParallelism: integer, units: { name: string, kind: string, start: number, end: number, duration: number }[], summary: { units: integer, byKind: table<string, { count: integer, time: number }> } }
function M.data()
	local out = {}
	local byKind = {}
	local totalTime = 0
	local count = 0
	for _, u in ipairs(units or {}) do
		if u["end"] ~= nil then
			local duration = u["end"] - u.start
			out[#out + 1] = {
				name = u.name,
				kind = u.kind,
				start = u.start,
				["end"] = u["end"],
				duration = duration,
			}
			local kindSum = byKind[u.kind] or { count = 0, time = 0 }
			kindSum.count += 1
			kindSum.time += duration
			byKind[u.kind] = kindSum
			totalTime = math.max(totalTime, u["end"])
			count += 1
		end
	end
	table.sort(out, function(a, b) return a.start < b.start end)
	-- Include trailing work (report write, final file moves) in the total.
	totalTime = math.max(totalTime, ansi.now() - t0)
	return {
		version = 1,
		ldeVersion = meta.version,
		command = meta.command,
		package = meta.package,
		startedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		totalTime = totalTime,
		maxParallelism = maxParallelism(out),
		units = out,
		summary = { units = count, byKind = byKind },
	}
end

--- Write the report as JSON (for machine/LLM consumption).
---@param path string
---@return boolean? ok
---@return string? err
function M.writeJSON(path)
	if not units then return nil, "no timings collected" end
	if not fs.write(path, json.encode(M.data())) then
		return nil, "failed to write " .. path
	end
	return true
end

---@param seconds number
---@return string
local function formatDuration(seconds)
	if seconds < 0.001 then return "<1ms" end
	if seconds < 1 then return string.format("%.0fms", seconds * 1000) end
	if seconds < 60 then return string.format("%.2fs", seconds) end
	local m = math.floor(seconds / 60)
	local s = seconds - m * 60
	return string.format("%dm%02.1fs", m, s)
end

---@param s string
---@return string
local function htmlEscape(s)
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

--- Round tick interval so roughly 8-12 ticks fit the axis.
---@param total number
---@return number
local function tickStep(total)
	local target = total / 10
	local steps = { 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200, 1800, 3600 }
	for _, s in ipairs(steps) do
		if s >= target then return s end
	end
	return math.ceil(target / 3600) * 3600
end

--- Greedy interval coloring: assign each unit the lowest lane whose last unit
--- ended before it starts, so overlapping units land on distinct rows. Returns
--- the units with a `lane` field (0-based) and the lane count.
---@param unitsList { start: number, end: number, lane: integer? }[]
---@return integer # number of lanes used
local function assignLanes(unitsList)
	local laneEnds = {}
	for _, u in ipairs(unitsList) do
		local lane
		for i = 1, #laneEnds do
			if laneEnds[i] <= u.start then lane = i break end
		end
		if not lane then
			lane = #laneEnds + 1
		end
		laneEnds[lane] = u["end"]
		u.lane = lane - 1
	end
	return #laneEnds
end

---@param data table # result of M.data()
---@return string
local function renderHTML(data)
	local total = data.totalTime
	if total <= 0 then total = 1 end
	local unitsList = data.units
	table.sort(unitsList, function(a, b) return a.start < b.start end)
	local lanes = assignLanes(unitsList)

	local cards = {
		{ v = formatDuration(data.totalTime), k = "Total time" },
		{ v = tostring(data.maxParallelism), k = "Max parallelism" },
		{ v = tostring(data.summary.units), k = "Units" },
	}
	local longest = nil
	for _, u in ipairs(unitsList) do
		if not longest or u.duration > longest.duration then longest = u end
	end
	if longest then
		cards[#cards + 1] = { v = formatDuration(longest.duration), k = "Longest task" }
	end
	local cardHTML = {}
	for _, c in ipairs(cards) do
		cardHTML[#cardHTML + 1] = '<div class="card"><div class="v">'
			.. htmlEscape(c.v) .. '</div><div class="k">' .. c.k .. "</div></div>"
	end

	-- Longest tasks table (by duration, descending).
	local rows = {}
	for i, u in ipairs(unitsList) do
		rows[#rows + 1] = u
	end
	table.sort(rows, function(a, b) return a.duration > b.duration end)
	local tableHTML = {}
	for i, u in ipairs(rows) do
		local color = KIND_COLORS[u.kind] or "#8b94a3"
		tableHTML[#tableHTML + 1] = "<tr><td>" .. i .. '</td><td>'
			.. htmlEscape(u.name) .. '</td><td><span class="badge" style="background:'
			.. color .. '">' .. htmlEscape(u.kind) .. "</span></td><td class=\"num\">"
			.. formatDuration(u.start) .. '</td><td class="num">'
			.. formatDuration(u.duration) .. "</td></tr>"
	end

	-- Time axis ruler (aligned with the chart's track column).
	local step = tickStep(total)
	local axis = {}
	for t = 0, total, step do
		local left = t / total * 100
		axis[#axis + 1] = '<span style="left:' .. left .. '%">'
			.. formatDuration(t) .. "</span>"
	end
	axis[#axis + 1] = '<span style="left:100%">' .. formatDuration(total) .. "</span>"

	-- Gantt rows: one lane per parallel slot.
	local gantt = {}
	for _, u in ipairs(unitsList) do
		local left = u.start / total * 100
		local width = u.duration / total * 100
		local color = KIND_COLORS[u.kind] or "#8b94a3"
		local title = htmlEscape(u.name .. " · " .. formatDuration(u.duration))
		gantt[#gantt + 1] = '<div class="row"><div class="rname" title="' .. title
			.. '">' .. htmlEscape(u.name) .. '</div><div class="track"><div class="bar" '
			.. 'style="left:' .. left .. '%;width:' .. width .. '%;background:' .. color .. '" '
			.. 'title="' .. title .. '"><span>' .. htmlEscape(u.name) .. "</span></div></div></div>"
	end

	-- Legend: kinds present, with counts and total time.
	local legend = {}
	for _, u in ipairs(unitsList) do
		local key = u.kind
		if not legend[key] then legend[key] = { color = KIND_COLORS[key] or "#8b94a3", count = 0, time = 0 } end
		local l = legend[key]
		l.count += 1
		l.time += u.duration
	end
	local legendHTML = {}
	for kind, l in pairs(legend) do
		legendHTML[#legendHTML + 1] = '<span><i style="background:' .. l.color
			.. '"></i>' .. htmlEscape(kind) .. " × " .. l.count .. " ("
			.. formatDuration(l.time) .. ")</span>"
	end

	local title = "lde timings · " .. tostring(data.package or "")
	local subtitle = table.concat({
		"Generated " .. htmlEscape(data.startedAt or ""),
		data.command and ("command: lde " .. htmlEscape(data.command)) or nil,
		data.ldeVersion and ("lde " .. htmlEscape(data.ldeVersion)) or nil,
	}, " · ")

	return [==[<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>]==] .. htmlEscape(title) .. [==[</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0f1115;color:#d5dae3;font:13px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;padding:28px 36px 64px}
h1{font-size:19px;font-weight:600;color:#f2f5fa}
.sub{color:#7d8590;font-size:12px;margin-top:5px}
.cards{display:flex;gap:12px;flex-wrap:wrap;margin:22px 0 8px}
.card{background:#161a22;border:1px solid #242b38;border-radius:8px;padding:12px 18px;min-width:120px}
.card .v{font-size:20px;font-weight:600;color:#f2f5fa;font-variant-numeric:tabular-nums}
.card .k{font-size:11px;color:#8b94a3;text-transform:uppercase;letter-spacing:.07em;margin-top:3px}
h2{font-size:12px;font-weight:600;color:#aeb6c2;text-transform:uppercase;letter-spacing:.09em;margin:30px 0 10px}
table{border-collapse:collapse;width:100%;max-width:860px}
th,td{text-align:left;padding:7px 10px;border-bottom:1px solid #1d2430;font-variant-numeric:tabular-nums}
th{color:#8b94a3;font-size:11px;text-transform:uppercase;letter-spacing:.06em;font-weight:600}
td.num,th.num{text-align:right}
.badge{display:inline-block;padding:1px 8px;border-radius:10px;font-size:11px;color:#0f1115;font-weight:600}
.chart{background:#101319;border:1px solid #1d2430;border-radius:8px;padding:16px 18px;overflow-x:auto}
.axis{display:flex;margin-bottom:6px}
.axis .gutter{flex:none;width:230px}
.axis .track{position:relative;flex:1;height:18px;border-bottom:1px solid #242b38}
.axis .track span{position:absolute;font-size:10px;color:#6b7484;transform:translateX(-50%);top:2px}
.row{display:flex;align-items:center;margin:3px 0}
.row .rname{flex:none;width:220px;padding-right:10px;font-size:11px;color:#aeb6c2;text-align:right;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.row .track{position:relative;flex:1;height:22px}
.bar{position:absolute;top:0;height:22px;border-radius:3px;min-width:2px;cursor:default;box-shadow:inset 0 0 0 1px #0006}
.bar:hover{filter:brightness(1.3)}
.bar span{position:absolute;left:6px;top:4px;font-size:11px;color:#fff;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:calc(100% - 12px);text-shadow:0 1px 2px #000a}
.legend{display:flex;gap:18px;flex-wrap:wrap;margin-top:12px;font-size:11px;color:#8b94a3}
.legend i{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:5px;vertical-align:-1px}
</style>
</head>
<body>
<h1>]==] .. htmlEscape(title) .. [==[</h1>
<div class="sub">]==] .. subtitle .. [==[</div>
<div class="cards">]==] .. table.concat(cardHTML) .. [==[</div>
<h2>Longest tasks</h2>
<table><tr><th>#</th><th>Name</th><th>Kind</th><th class="num">Start</th><th class="num">Duration</th></tr>]==]
		.. table.concat(tableHTML) .. [==[</table>
<h2>Timeline (]==] .. lanes .. [==[ parallel lane(s))</h2>
<div class="chart"><div class="axis"><div class="gutter"></div><div class="track">]==]
		.. table.concat(axis) .. [==[</div></div>]==] .. table.concat(gantt) .. [==[</div>
<div class="legend">]==] .. table.concat(legendHTML) .. [==[</div>
</body>
</html>]==]
end

--- Write the report as a self-contained HTML file.
---@param path string
---@return boolean? ok
---@return string? err
function M.writeHTML(path)
	if not units then return nil, "no timings collected" end
	local html = renderHTML(M.data())
	if not fs.write(path, html) then
		return nil, "failed to write " .. path
	end
	return true
end

return M
