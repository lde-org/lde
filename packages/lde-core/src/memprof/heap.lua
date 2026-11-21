-- Heap snapshots for `lde run --memprof`. lua-sys's state:heapSnapshot() attributes reachable bytes to retainer paths. Leak suspects are the paths that keep growing from one snapshot to the next.
--
-- Automatic snapshots run from the profiler callback, where the guest's locals are still live. The guest can also take labeled snapshots with `require("lde.memprof").snapshot(label)`.

const MODULE_NAME = "lde.memprof"

const FIRST_SNAPSHOT_MS = 10
const MAX_SNAPSHOT_GAP_MS = 10000
const MAX_SNAPSHOTS = 16
const WALK_BUDGET = 0.1 -- automatic walks may take this share of the profiled CPU time
const MIN_LEAK_BYTES = 16 * 1024
const LEAK_SHARE_OF_TOP = 0.05
const DESCEND_SHARE = 0.8
const STEADY_SHARE = 0.6

---@class lde.memprof.Snapshot
---@field label      string?
---@field atMs       number  # profiled CPU time when the snapshot was taken
---@field attributed number  # bytes the walk attributed to paths
---@field objects    number
---@field retained   table<string, number> # path → bytes reachable through it
---@field counts     table<string, number> # path → objects whose path is exactly this one

---@class lde.memprof.Leak
---@field path   string
---@field growth number    # retained bytes, last snapshot minus first
---@field items  integer   # element count growth of the path's collection
---@field series number[]  # retained bytes per snapshot

---@class lde.memprof.Heap
---@field state       lua.State
---@field parents     table<string, string|false>
---@field auto        lde.memprof.Snapshot[]
---@field manual      lde.memprof.Snapshot[]
---@field clockMs     number
---@field nextAtMs    number
---@field gapMs       number
---@field skipMs      number # CPU time spent walking; the profiler would charge it to unrelated stacks
---@field walkedMs    number # CPU time of all automatic walks so far
---@field isWalking   boolean
---@field error       string?
const Heap = {}
Heap.__index = Heap

---@param list lde.memprof.Snapshot[]
local function thin(list)
	if #list <= MAX_SNAPSHOTS then return list end
	const kept = {}
	for i = 1, #list do
		if i % 2 == 1 or i == #list then kept[#kept + 1] = list[i] end
	end
	return kept
end

--- Register `require("lde.memprof")` in the guest. Call before the chunk runs.
---@param state lua.State
function Heap.install(state)
	const self = setmetatable({
		state = state,
		parents = {},
		auto = {},
		manual = {},
		clockMs = 0,
		nextAtMs = FIRST_SNAPSHOT_MS,
		gapMs = FIRST_SNAPSHOT_MS,
		skipMs = 0,
		walkedMs = 0,
		isWalking = false,
	}, Heap)

	const loaded = state:globals().package.loaded
	loaded[MODULE_NAME] = state:table({
		---@param label any
		snapshot = function(label)
			self:take(label ~= nil and tostring(label) or "")
		end,
	})
	return self
end

--- A nil label is an automatic snapshot, taken from the profiler callback.
---@param label string?
function Heap:take(label)
	if self.error then return end
	const started = os.clock()
	-- The walk can call the guest's ffi.sizeof, which can fire the profiler callback: it skips samples while this is set.
	self.isWalking = true
	const ok, result = pcall(self.state.heapSnapshot, self.state)
	self.isWalking = false
	if not label then self.skipMs += (os.clock() - started) * 1000 end

	if not ok then
		self.error = tostring(result)
		return
	end
	const walked = result --[[@as lua.HeapSnapshot]]
	for path, parent in pairs(walked.parents) do self.parents[path] = parent end
	---@type lde.memprof.Snapshot
	const snapshot = {
		label = label,
		atMs = self.clockMs,
		attributed = walked.attributed,
		objects = walked.objects,
		retained = walked.retained,
		counts = walked.counts,
	}
	if label then
		self.manual[#self.manual + 1] = snapshot
		self.manual = thin(self.manual)
	else
		self.auto[#self.auto + 1] = snapshot
		self.auto = thin(self.auto)
	end
end

--- Drop samples that the profiler accumulated while a snapshot ran.
---@param samples integer
---@param msPerSample number
function Heap:discount(samples, msPerSample)
	if self.skipMs <= 0 then return samples end
	const skipped = math.min(samples, math.floor(self.skipMs / msPerSample + 0.5))
	self.skipMs = math.max(0, self.skipMs - skipped * msPerSample)
	return samples - skipped
end

--- Called from the profiler callback with the profiled CPU time. Takes an automatic snapshot when one is due: the gap doubles up to MAX_SNAPSHOT_GAP_MS, and walks wait while they used more than WALK_BUDGET of the run so far.
---@param nowMs number
function Heap:sample(nowMs)
	self.clockMs = nowMs
	if nowMs < self.nextAtMs or self.walkedMs > nowMs * WALK_BUDGET then return end
	const skippedBefore = self.skipMs
	self:take(nil)
	self.walkedMs += self.skipMs - skippedBefore
	self.gapMs = math.min(self.gapMs * 2, MAX_SNAPSHOT_GAP_MS)
	self.nextAtMs = nowMs + self.gapMs
end

--- The snapshot series used for leak detection: the labeled snapshots when there are two or more, otherwise the automatic ones.
function Heap:series()
	return #self.manual >= 2 and self.manual or self.auto
end

--- Paths whose retained bytes grew steadily over the series, largest growth first. A suspect is the deepest named path that still holds most of the growth, so `cache.entries` is reported rather than `cache`.
---@return lde.memprof.Leak[]
function Heap:leaks()
	const series = self:series()
	if #series < 2 then return {} end
	const first, last = series[1], series[#series]
	const parents = self.parents

	---@param path string
	local function growth(path)
		return (last.retained[path] or 0) - (first.retained[path] or 0)
	end

	---@type table<string, string[]>
	const children = {}
	---@type string[]
	const roots = {}
	for path in pairs(last.retained) do
		const parent = parents[path]
		if parent then
			const list = children[parent] or {}
			list[#list + 1] = path
			children[parent] = list
		else
			roots[#roots + 1] = path
		end
	end

	local topGrowth = 0
	for _, root in ipairs(roots) do topGrowth = math.max(topGrowth, growth(root)) end
	const threshold = math.max(MIN_LEAK_BYTES, topGrowth * LEAK_SHARE_OF_TOP)

	---@param path string
	local function isSteady(path)
		if #series < 3 then return true end
		local rises = 0
		for i = 2, #series do
			if (series[i].retained[path] or 0) > (series[i - 1].retained[path] or 0) then rises += 1 end
		end
		return rises >= (#series - 1) * STEADY_SHARE
	end

	---@type string[]
	const found = {}
	---@param path string
	local function descend(path)
		const named = {}
		local namedGrowth = 0
		for _, child in ipairs(children[path] or {}) do
			const segment = child:sub(#path + 1)
			if segment ~= "[]" and segment ~= "[*]" then
				const childGrowth = growth(child)
				if childGrowth >= threshold then
					named[#named + 1] = child
					namedGrowth += childGrowth
				end
			end
		end
		if #named > 0 and namedGrowth >= growth(path) * DESCEND_SHARE then
			for _, child in ipairs(named) do descend(child) end
		elseif isSteady(path) then
			found[#found + 1] = path
		end
	end
	for _, root in ipairs(roots) do
		if growth(root) >= threshold then descend(root) end
	end

	---@param snapshot lde.memprof.Snapshot
	---@param path string
	local function items(snapshot, path)
		return (snapshot.counts[path .. "[]"] or 0) + (snapshot.counts[path .. "[*]"] or 0)
	end

	---@type lde.memprof.Leak[]
	const leaks = {}
	for _, path in ipairs(found) do
		const values = {}
		for i, snapshot in ipairs(series) do values[i] = snapshot.retained[path] or 0 end
		leaks[#leaks + 1] = {
			path = path,
			growth = growth(path),
			items = items(last, path) - items(first, path),
			series = values,
		}
	end
	table.sort(leaks, |a, b| -> a.growth > b.growth)
	return leaks
end

--- Remove `lde.memprof` from the guest so the exit measurement does not include it.
function Heap:close()
	if self.state.L == nil then return end
	self.state:globals().package.loaded[MODULE_NAME] = nil
end

return Heap
