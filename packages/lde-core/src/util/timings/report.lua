--- Reporting side of the timings collector: the HTML/JSON writers, kept out of
--- the collection module so `require("lde-core.util.timings")` (loaded on every
--- install/run) does not pull a Gantt renderer and its templates.

---@type table<string, string>
const KIND_COLORS = {
	build = "#4c9be8",
	download = "#e8764c",
	bundle = "#b44ce8",
	compile = "#e84c6b",
}

local report = {}

---@param seconds number
local function formatDuration(seconds)
	if seconds < 0.001 then return "<1ms" end
	if seconds < 1 then return string.format("%.0fms", seconds * 1000) end
	if seconds < 60 then return string.format("%.2fs", seconds) end
	local m = math.floor(seconds / 60)
	const s = seconds - m * 60
	return string.format("%dm%02.1fs", m, s)
end

---@param s string
local function htmlEscape(s)
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

---@param total number
---@return number
local function tickStep(total)
	const target = total / 10
	const steps = { 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200, 1800, 3600 }
	for _, s in ipairs(steps) do
		if s >= target then return s end
	end
	return math.ceil(target / 3600) * 3600
end

---@param unitsList { start: number, end: number, lane: integer? }[]
local function assignLanes(unitsList)
	const laneEnds = {}
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
local function renderHTML(data)
	local total = data.totalTime
	if total <= 0 then total = 1 end
	local unitsList = data.units
	table.sort(unitsList, |a, b| -> a.start < b.start)
	const lanes = assignLanes(unitsList)

	const cards = {
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
	const cardHTML = {}
	for _, c in ipairs(cards) do
		cardHTML[#cardHTML + 1] = '<div class="card"><div class="v">'
			.. htmlEscape(c.v) .. '</div><div class="k">' .. c.k .. "</div></div>"
	end

	local rows = {}
	for i, u in ipairs(unitsList) do
		rows[#rows + 1] = u
	end
	table.sort(rows, |a, b| -> a.duration > b.duration)
	const tableHTML = {}
	for i, u in ipairs(rows) do
		local color = KIND_COLORS[u.kind] or "#8b94a3"
		tableHTML[#tableHTML + 1] = "<tr><td>" .. i .. '</td><td>'
			.. htmlEscape(u.name) .. '</td><td><span class="badge" style="background:'
			.. color .. '">' .. htmlEscape(u.kind) .. "</span></td><td class=\"num\">"
			.. formatDuration(u.start) .. '</td><td class="num">'
			.. formatDuration(u.duration) .. "</td></tr>"
	end

	const step = tickStep(total)
	const axis = {}
	for t = 0, total, step do
		local left = t / total * 100
		axis[#axis + 1] = '<span style="left:' .. left .. '%">'
			.. formatDuration(t) .. "</span>"
	end
	axis[#axis + 1] = '<span style="left:100%">' .. formatDuration(total) .. "</span>"

	const gantt = {}
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

	const legend = {}
	for _, u in ipairs(unitsList) do
		const key = u.kind
		if not legend[key] then legend[key] = { color = KIND_COLORS[key] or "#8b94a3", count = 0, time = 0 } end
		const l = legend[key]
		l.count += 1
		l.time += u.duration
	end
	const legendHTML = {}
	for kind, l in pairs(legend) do
		legendHTML[#legendHTML + 1] = '<span><i style="background:' .. l.color
			.. '"></i>' .. htmlEscape(kind) .. " × " .. l.count .. " ("
			.. formatDuration(l.time) .. ")</span>"
	end

	local title = "lde timings · " .. tostring(data.package or "")
	const subtitleParts = { "Generated " .. htmlEscape(data.startedAt or "") }
	if data.command then subtitleParts[#subtitleParts + 1] = "command: lde " .. htmlEscape(data.command) end
	if data.ldeVersion then subtitleParts[#subtitleParts + 1] = "lde " .. htmlEscape(data.ldeVersion) end
	const subtitle = table.concat(subtitleParts, " · ")

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

report.renderHTML = renderHTML

return report
