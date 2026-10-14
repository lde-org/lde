--- Build scheduler for the install build pass: queues resolved nodes and
--- starts each build once the node's dependencies have finished, so builds
--- overlap the download tail.

const fs = require("fs")
const path = require("path")
const ffi = require("ffi")

local lde = require("lde-core")
local resolve = require("lde-core.package.install.resolve")
const timings = require("lde-core.util.timings")
const lock = require("lde-core.package.install.lock")
const asyncBuild = require("lde-core.util.async-build")

--- Build scheduler for the install build pass.
---
--- Nodes become buildable the moment their content is materialized *and* every
--- dependency whose build they can read has finished, so independent rocks
--- (and their gcc compiles) start building while the download batch is still
--- draining — overlapping the build with the download tail. Ordering
--- constraints are preserved via `hasBuildDeps` (the same rule the old
--- sequential loop used).
---@param ctx lde.install.Context
---@return { addNode: fun(node: lde.install.Node), finish: fun() }
local function new(ctx)

	-- Cross-platform sleep used while polling spawned build workers so the
	-- loop doesn't busy-wait between checks.
	local sleep
	if jit.os == "Windows" then
		pcall(ffi.cdef, "void Sleep(unsigned long dwMilliseconds);")
		sleep = function(ms) ffi.C.Sleep(ms) end
	else
		pcall(ffi.cdef, "int usleep(unsigned int usec);")
		sleep = function(ms) ffi.C.usleep(ms * 1000) end
	end

	---@type { alias: string, build: lde.install.DeferredBuild, handle: timings.Handle? }[]
	local pending = {}
	---@type table<string, boolean>
	local done = {}      -- alias -> build finished or skipped
	---@type lde.install.Node[]
	const queue = {}     -- content-ready nodes waiting to build
	---@type table<string, boolean>
	const queued = {}    -- alias -> addNode already ran
	---@type table<string, boolean>
	const attempted = {} -- alias -> attemptBuild already ran
	---@type table<string, table<string, true>> # alias -> direct dependency aliases (build graph edges)
	const children = {}
	---@type table<string, boolean>
	const building = {}  -- alias -> a build is in flight (row shown on the progress region)

	-- Forward declarations: the functions below reference each other.
	local pumpQueue
	local attemptBuild

	--- How many of a dependency's transitive closure (itself included) are
	--- built so far, and its total size. Shown on that dependency's progress
	--- row as `built/total` — e.g. `curl-sys 3/8` means 3 of the 8 packages
	--- curl-sys pulls in are built.
	---@param alias string
	---@return integer built
	---@return integer total
	local function subtreeCount(alias)
		const seen = { [alias] = true }
		const frontier = { alias }
		local built, total = done[alias] ? 1 : 0, 1
		while #frontier > 0 do
			const a = table.remove(frontier)
			for child in pairs(children[a] or {}) do
				if not seen[child] then
					seen[child] = true
					total += 1
					if done[child] then built += 1 end
					frontier[#frontier + 1] = child
				end
			end
		end
		return built, total
	end

	--- Push the completed/total counts onto the install progress region:
	--- the total bar (install-wide done/total) and each building row's own
	--- built/total count.
	local function updateProgress()
		if not ctx.progress then return end
		local doneCount, total = 0, 0
		for _ in pairs(done) do doneCount += 1 end
		for _ in pairs(ctx.stack) do total += 1 end
		ctx.progress:update(total > 0 ? doneCount / total : nil, doneCount .. "/" .. total)
		for alias in pairs(building) do
			local built, sub = subtreeCount(alias)
			ctx.progress:setDepCount(alias, built, sub)
		end
	end

	--- Drop a finished dependency from the progress region (its row clears)
	--- and push the total bar forward.
	---@param alias string
	local function finishAlias(alias)
		building[alias] = nil
		if ctx.progress then
			ctx.progress:finish(alias)
			updateProgress()
		end
	end

	--- Whether a node's build may run now: its package is open, and every dep
	--- it can read outputs from has finished building.
	---@param node lde.install.Node
	---@return boolean
	local function ready(node)
		if not ctx.stack[node.alias] then return false end
		local entry = ctx.stack[node.alias]
		if entry.pkg.hasBuildDeps ~= false then
			for depAlias in pairs(node.deps or {}) do
				if not done[depAlias] then return false end
			end
		end
		return true
	end

	--- Run a deferred finalizer once its spawned compiles finished.
	---@param job { alias: string, build: lde.install.DeferredBuild, handle: timings.Handle? }
	local function finalizeJob(job)
		local ok, err = job.build.finalize()
		if not ok then
			lde.error.raise("Build failed for '" .. job.alias .. "': " .. tostring(err))
		end
		if job.handle then timings.finish(job.handle) end
		ctx.builds += 1
		done[job.alias] = true
		finishAlias(job.alias)
		pumpQueue()
	end

	--- Attempt to build one node (spawning gcc async when asyncBuild is active).
	---@param node lde.install.Node
	attemptBuild = function(node)
		local alias = node.alias
		if attempted[alias] then return end
		local entry = ctx.stack[alias]
		if not entry then return end

		-- Optional deps nothing wants: skip, but mark them done so dependents
		-- don't wait on them (clearing any download-time row the resolver
		-- spawned). The node says so itself -- the walk asks every package it
		-- reaches which of its optional deps its features turn on, so a dep that
		-- a *dependency* leaves off is skipped the same way one the root does.
		if node.wanted == false then
			attempted[alias] = true
			done[alias] = true
			if ctx.progress then ctx.progress:finish(alias) end
			return
		end

		if not ready(node) then return end
		attempted[alias] = true

		local dest = path.join(ctx.modulesDir, alias)

		-- Git/registry deps are symlinked (or built) into target/, and the
		-- symlink target encodes the resolved commit. Drop a stale link from a
		-- previous commit before the build re-creates it.
		if entry.lock.git and fs.islink(dest) then
			fs.delete(dest)
		end

		-- Already a symlink (path deps / no-build git deps): nothing to build.
		-- Clear any download-time row the resolver spawned for this dep.
		if fs.islink(dest) then
			done[alias] = true
			if ctx.progress then
				ctx.progress:finish(alias)
				updateProgress()
			end
			return
		end

		-- The progress region keeps (or spawns) a row for this dependency while
		-- its build runs (cleared again by finishAlias). Only deps that do real
		-- work build here; the marker is picked lazily from what is already
		-- known — no I/O beyond the one stat below.
		local pkg = entry.pkg
		const hasBuildLua = fs.exists(pkg:getBuildScriptPath())
		const isBuild = pkg.buildfn ~= nil or hasBuildLua
		if ctx.progress and isBuild then
			building[alias] = true
			const kind = hasBuildLua ? "tools" : pkg.isRockspec ? "rock" : "wrench"
			ctx.progress:setCurrent(alias, kind)
		end

		-- The unit spans the real build: from pkg:build() to the deferred
		-- finalizer (spawned compiles draining) or the synchronous return.
		const buildHandle = timings.active() ? timings.start("build " .. alias, "build") : nil
		local hasBuilt, deferred = pkg:build(dest)
		if deferred then
			pending[#pending + 1] = { alias = alias, build = deferred, handle = buildHandle, lock = deferred.lock }
		else
			if buildHandle then timings.finish(buildHandle) end
			done[alias] = true
			if hasBuilt then ctx.builds += 1 end
			-- finish is a no-op when the dep never spawned a row (no build
			-- script, or a cached build that returned early).
			building[alias] = nil
			if ctx.progress then
				ctx.progress:finish(alias)
				updateProgress()
			end
			pumpQueue()
		end
	end

	--- Try to build every queued node that is now ready.
	pumpQueue = function()
		local hasProgressed = true
		while hasProgressed do
			hasProgressed = false
			for _, node in ipairs(queue) do
				if not attempted[node.alias] and ready(node) then
					attemptBuild(node)
					hasProgressed = true
				end
			end
		end
	end
	const scheduler = {}

	--- Queue a node for building; opens its package and records its stack
	--- entry first (once per alias). Idempotent per alias.
	---@param node lde.install.Node
	function scheduler.addNode(node)
		local alias = node.alias
		if queued[alias] then return end
		queued[alias] = true
		queue[#queue + 1] = node
		-- Record the build-graph edge (used for per-dependency subtree counts).
		const set = children[alias] or {}
		for depAlias in pairs(node.deps or {}) do set[depAlias] = true end
		children[alias] = set
		if not ctx.stack[alias] then
			resolve.registerNode(node, ctx)
		end
		pumpQueue()
	end

	--- Wait for all spawned compiles, then build whatever is left. Finalize
	--- each job as soon as its children exit (rather than in spawn order) so
	--- progress bars report accurate elapsed times and dependents unblock
	--- promptly.
	function scheduler.finish()
		while #pending > 0 do
			local hasProgressed = false
			local i = 1
			while i <= #pending do
				const job = pending[i]
				if job.build.poll() ~= nil then
					table.remove(pending, i)
					finalizeJob(job)
					hasProgressed = true
					-- finalizeJob may pump the queue and append new jobs; keep
					-- this index to re-check the element that shifted into it.
				else
					i += 1
				end
			end
			if not hasProgressed then
				-- Heartbeat the held build locks so a waiter does not steal them
				-- while a long native compile is still running.
				for _, job in ipairs(pending) do lock.touch(job.lock) end
				sleep(20)
				-- Refresh the progress region while spawned build workers run:
				-- per-row elapsed counters animate and each row's built/total
				-- count stays current as dependencies finish around it.
				if ctx.progress then updateProgress() end
			end
		end
		pumpQueue()
		asyncBuild.finish()
	end

	asyncBuild.begin()
	return scheduler
end

return { new = new }
