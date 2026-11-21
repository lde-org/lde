-- Memory side of `lde run --memprof`. On each profiler sample it reads the guest allocator: growth since the previous sample is charged to the stack that is running, and goes into a timeline of fixed-width buckets. Heap snapshots for leak suspects come from lde-core.memprof.heap.

const raw = require("lua-sys.raw")
const memprofHeap = require("lde-core.memprof.heap")

const LUA_GCCOLLECT = 2
const MAX_BUCKETS = 400
const NO_STACK = "(no Lua frame)"

---@class lde.memprof.Bucket
---@field atMs      number # profiled CPU time where the bucket starts
---@field bytes     number # guest bytes at the last sample in the bucket
---@field peak      number
---@field allocated number # sampled growth inside the bucket
---@field sites     table<string, number> # stack → sampled growth inside the bucket

---@class lde.MemoryProfile
---@field intervalMs number
---@field baseline   number
---@field current    number
---@field peak       number
---@field allocated  number # sampled positive growth, not retained bytes
---@field stacks     table<string, number> # stack ("fn@file:line;caller@file:line") → sampled growth
---@field bucketMs   number
---@field timeline   lde.memprof.Bucket[]
---@field isArmed    boolean
---@field lastStack  string?
---@field final      number?
---@field retained   number?
---@field snapshots  lde.memprof.Snapshot[]?
---@field leaks      lde.memprof.Leak[]?
---@field heapError  string?
---@field state      lua.State
---@field heap       lde.memprof.Heap
const Memory = {}
Memory.__index = Memory

--- Two full collections: finalizers and weak tables can release more on the second.
---@param state lua.State
local function collect(state)
	const L = assert(state.L, "state is closed")
	raw.gc(L, LUA_GCCOLLECT, 0)
	raw.gc(L, LUA_GCCOLLECT, 0)
end

---@param state lua.State
---@param intervalMs number
---@return lde.MemoryProfile
function Memory.new(state, intervalMs)
	return setmetatable({
		intervalMs = intervalMs,
		baseline = 0,
		current = 0,
		peak = 0,
		allocated = 0,
		stacks = {},
		bucketMs = intervalMs,
		timeline = {},
		isArmed = false,
		state = state,
		heap = memprofHeap.install(state),
	}, Memory)
end

--- Take the baseline after the chunk is loaded and collected, so compilation temporaries are not program memory and both ends are post-GC.
function Memory:arm()
	if self.isArmed then return end
	collect(self.state)
	self.baseline = self.state:memory()
	self.current = self.baseline
	self.peak = self.baseline
	self.isArmed = true
end

-- Halve the timeline's resolution: it keeps MAX_BUCKETS buckets however long the run is.
function Memory:mergeBuckets()
	const merged = {}
	for i = 1, #self.timeline, 2 do
		const a, b = self.timeline[i], self.timeline[i + 1]
		if b then
			for site, bytes in pairs(b.sites) do a.sites[site] = (a.sites[site] or 0) + bytes end
			a.bytes = b.bytes
			a.peak = math.max(a.peak, b.peak)
			a.allocated += b.allocated
		end
		merged[#merged + 1] = a
	end
	self.timeline = merged
	self.bucketMs *= 2
end

---@param nowMs number
---@param bytes number
---@param growth number
---@param stack string
function Memory:record(nowMs, bytes, growth, stack)
	local index = math.floor(nowMs / self.bucketMs) + 1
	while index > MAX_BUCKETS do
		self:mergeBuckets()
		index = math.floor(nowMs / self.bucketMs) + 1
	end
	const timeline = self.timeline
	-- Samples dropped while a snapshot ran leave gaps: carry the heap size over them.
	for i = #timeline + 1, index do
		const previous = timeline[i - 1]
		const carried = previous and previous.bytes or bytes
		timeline[i] = { atMs = (i - 1) * self.bucketMs, bytes = carried, peak = carried, allocated = 0, sites = {} }
	end
	const bucket = timeline[index]
	bucket.bytes = bytes
	if bytes > bucket.peak then bucket.peak = bytes end
	if growth > 0 then
		bucket.allocated += growth
		bucket.sites[stack] = (bucket.sites[stack] or 0) + growth
	end
end

---@param nowMs number
---@param stack string?
function Memory:account(nowMs, stack)
	const now = self.state:memory()
	const growth = now - self.current
	const site = stack or self.lastStack or NO_STACK
	self.current = now
	if now > self.peak then self.peak = now end
	if growth > 0 then
		self.allocated += growth
		self.stacks[site] = (self.stacks[site] or 0) + growth
	end
	if stack then self.lastStack = stack end
	self:record(nowMs, now, growth, site)
end

--- Called on each profiler sample. `stack` is the running Lua stack, innermost frame first, or nil inside the GC or without Lua frames: growth then goes to the previous stack, which ran the code that triggered it.
---@param nowMs number # profiled CPU time
---@param stack string?
function Memory:sample(nowMs, stack)
	if not self.isArmed then return end
	self:account(nowMs, stack)
	self.heap:sample(nowMs)
end

--- Stop: account the time since the last sample, collect leak suspects, then measure what survives exit.
---@param nowMs number
function Memory:finish(nowMs)
	if self.isArmed then self:account(nowMs, nil) end
	self.leaks = self.heap:leaks()
	self.snapshots = self.heap:series()
	self.heapError = self.heap.error
	self.heap:close()
	if not self.isArmed then return end
	collect(self.state)
	const final = self.state:memory()
	self.final = final
	if final > self.peak then self.peak = final end
	self.retained = final - self.baseline
end

return Memory
