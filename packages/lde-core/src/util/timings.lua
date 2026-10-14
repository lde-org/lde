const ansi = require("ansi")
const fs = require("fs")
const json = require("json")

--- Build timings report writer (`lde sync --timings`, `lde compile --timings`); collection is opt-in (recording helpers are no-ops until begin()), so the pipeline pays nothing unless asked.

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



const M = {}

---@param opts { command: string?, package: string?, version: string? }?
function M.begin(opts)
	units = {}
	t0 = ansi.now()
	meta = opts or {}
end

function M.active()
	return units ~= nil
end

function M.reset()
	units = nil
end

---@param name string
---@param kind string
---@return timings.Handle?
function M.start(name, kind)
	if not units then return nil end
	local unit = { name = name, kind = kind, start = ansi.now() - t0, ["end"] = nil }
	units[#units + 1] = unit
	return { unit = unit }
end

---@param handle timings.Handle?
function M.finish(handle)
	if not handle or handle.unit["end"] ~= nil then return end
	handle.unit["end"] = ansi.now() - t0
end

---@param unitsList { start: number, end: number? }[]
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
			const kindSum = byKind[u.kind] or { count = 0, time = 0 }
			kindSum.count += 1
			kindSum.time += duration
			byKind[u.kind] = kindSum
			totalTime = math.max(totalTime, u["end"])
			count += 1
		end
	end
	table.sort(out, |a, b| -> a.start < b.start)
	-- Include trailing work (report write, final file moves) in the total.
	totalTime = math.max(totalTime, ansi.now() - t0)
	return {
		version = 1,
		ldeVersion = meta.version,
		command = meta.command,
		package = meta.package,
		-- Format is fixed, so the result is the string it spells rather than the `osdate` a `*t` format would give; `string|osdate` is the definition's return for both.
		startedAt = os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]],
		totalTime = totalTime,
		maxParallelism = maxParallelism(out),
		units = out,
		summary = { units = count, byKind = byKind },
	}
end

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

---@param path string
---@return boolean? ok
---@return string? err
function M.writeHTML(path)
	if not units then return nil, "no timings collected" end
	const html = require("lde-core.util.timings.report").renderHTML(M.data())
	if not fs.write(path, html) then
		return nil, "failed to write " .. path
	end
	return true
end

return M
