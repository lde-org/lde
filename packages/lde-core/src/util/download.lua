local fs = require("fs")
local path = require("path")
local util = require("util")

local curl = util.lazy(|| -> require("curl-sys"))

--- Parallel download session used during dependency installation.
---
--- The install resolver discovers the dependency graph level by level. For
--- each level it prefetches every known source (`.src.rock` files, rockspecs,
--- git tarballs) into the local caches *in parallel*, then `drain()`s the
--- batch. The sequential resolution work that follows therefore hits the
--- cache instead of the network.
---
--- `background()` transfers (used for overlapped `install rocks:` root
--- downloads) are not waited on by `drain()`: they keep downloading while the
--- resolver proceeds and are collected with `waitBackground()` (or by
--- `finish()`).
---
--- Outside of an active session (`download.active()` == false) everything
--- falls back to the plain synchronous `curl.*` calls, so non-install paths
--- (e.g. `lde install --git`, bundling, `ensureMingw`) are unaffected.

local download = {}

---@class download.Batch
---@field add fun(self: download.Batch, url: string, opts?: table): integer
---@field results fun(self: download.Batch): table[]
---@field pump fun(self: download.Batch): integer
---@field wait fun(self: download.Batch, ms?: integer)
---@field runAll fun(self: download.Batch)
---@field close fun(self: download.Batch)

---@class download.Session
---@field batch download.Batch
---@field pending table<string, integer|table>  destPath -> batch transfer index (a result table once resolved)
---@field background table<string, boolean>  destPath -> true for transfers drain() must not block on
---@field onTransfer fun(destPath: string)? # fired once per completed transfer, after its result is resolved
---@field progress fun(done: integer, total: integer)?
---@field archiveCache string? # user-level dir of reusable downloaded bytes (keyed by destPath basename)

---@type download.Session?
local session = nil

--- Start a parallel download session. Blocks until everything finishes.
---@param opts table?  -- { progress: fun(done, total)?, archiveCache: string? }
function download.begin(opts)
	assert(not session, "download session already active")
	session = {
		batch = curl().batch({ progress = opts and opts.progress or nil }) --[[@as download.Batch]],
		pending = {},
		background = {},
		archiveCache = opts and opts.archiveCache,
	}
end

--- End the session, blocking until any still-running transfers finish.
function download.finish()
	if not session then return end
	session.batch:runAll()
	session.batch:close()
	session = nil
end

--- Abort the session without waiting for pending transfers.
function download.abort()
	if not session then return end
	session.batch:close()
	session = nil
end

---@return boolean true while a download session is active
function download.active()
	return session ~= nil
end

--- Whether a pending transfer has finished (result table available).
---@param destPath string
---@return boolean
local function transferDone(destPath) ---@cast session -nil
	local index = session.pending[destPath]
	if type(index) ~= "number" then return true end
	local res = session.batch:results()[index]
	return res ~= nil and res.err ~= "transfer not finished"
end

---@return boolean true when any non-background transfer is still running
local function pendingNonBackground() ---@cast session -nil
	for destPath, index in pairs(session.pending) do
		if type(index) == "number" and not session.background[destPath] then
			if not transferDone(destPath) then return true end
		end
	end
	return false
end

--- Resolve a finished transfer's pending entry into its result table, and
--- persist successful content into the user-level archive cache so future
--- trees can seed from it instead of re-downloading.
---@param destPath string
local function resolveTransfer(destPath) ---@cast session -nil
	local index = session.pending[destPath]
	if type(index) ~= "number" then return end
	local res = session.batch:results()[index] or { ok = false, err = "missing result" }
	session.pending[destPath] = res
	session.background[destPath] = nil
	if res.ok and res.path and session.archiveCache then
		local cached = path.join(session.archiveCache, path.basename(res.path))
		if not fs.exists(cached) then
			-- Copy to a temp name and rename: an interrupted copy must not
			-- leave a partial file that later runs trust as a full download.
			fs.mkdirAll(path.dirname(cached))
			local tmp = cached .. ".tmp"
			fs.copy(res.path, tmp)
			fs.move(tmp, cached)
		end
	end
end

--- Pump the batch until `waitFor` finishes, or until every non-background
--- transfer is done when `waitFor` is nil.
---@param waitFor string?
local function pumpUntil(waitFor)
	if not session then return end
	while true do
		if waitFor ~= nil then
			if transferDone(waitFor) then return end
		elseif not pendingNonBackground() then
			return
		end
		local running = session.batch:pump()
		if running > 0 then session.batch:wait(10) end
		-- Fire completion callbacks for transfers that finished this round.
		if session.onTransfer then
			for destPath, index in pairs(session.pending) do
				if type(index) == "number" and transferDone(destPath) then
					resolveTransfer(destPath)
					session.onTransfer(destPath)
				end
			end
		end
	end
end

--- Register a callback fired once per completed transfer (after its pending
--- entry has been resolved to a result table). Used to pipeline work under the
--- download tail.
---@param fn fun(destPath: string)?
function download.onTransfer(fn)
	if session then session.onTransfer = fn end
end

--- Total-time budget for each parallel transfer. A server that accepts the
--- connection but never finishes the body would otherwise block the batch
--- forever (curl-sys applies no default timeout).
local DOWNLOAD_TIMEOUT = 120 -- seconds

--- Seed `destPath` from the user-level archive cache when a copy exists
--- (keyed by destPath basename, which is URL-derived). Returns true when
--- seeded, so the caller can skip the network transfer entirely.
---
--- A file already at `destPath` is only trusted when it is (a) a transfer
--- registered this session (in flight or already resolved) or (b) backed by a
--- copy in the user-level archive cache, which is written only after a
--- successful transfer. A bare leftover from an interrupted run is a partial
--- download — it is deleted so the caller re-fetches instead of extracting
--- garbage.
---@param destPath string
---@return boolean
local function seedFromCache(destPath) ---@cast session -nil
	if fs.exists(destPath) then
		if type(session.pending[destPath]) == "number" then return true end
		local cached = session.archiveCache and path.join(session.archiveCache, path.basename(destPath))
		if cached and fs.exists(cached) then
			-- The leftover may be a partial download from an interrupted run;
			-- reseed it from the complete user-level copy instead of trusting it.
			fs.copy(cached, destPath)
			return true
		end
		fs.delete(destPath)
		return false
	end
	if not session.archiveCache then return false end
	local cached = path.join(session.archiveCache, path.basename(destPath))
	if not fs.exists(cached) then return false end
	fs.mkdirAll(path.dirname(destPath))
	fs.copy(cached, destPath)
	return true
end

--- Delete the user-level archive cache copy backing `destPath`. Called after
--- extraction of seeded content fails: the copy may itself be corrupt, and
--- must not be re-trusted (and re-failed) on the next run.
---@param destPath string
function download.invalidateUserCache(destPath)
	if not session or not session.archiveCache then return end
	fs.delete(path.join(session.archiveCache, path.basename(destPath)))
end

--- Register a URL to be fetched into `destPath` as part of the current batch.
--- Returns "pending" when a session is active (the file is not guaranteed to
--- exist until `drain()` is called), or "done" when no session is active
--- (callers should fall back to a synchronous download).
---@param url string
---@param destPath string
---@return "pending"|"done"
function download.prefetch(url, destPath)
	if not session then return "done" end
	if seedFromCache(destPath) then return "done" end
	local index = session.batch:add(url, { path = destPath, timeout = DOWNLOAD_TIMEOUT })
	session.pending[destPath] = index
	return "pending"
end

--- Like `prefetch`, but `drain()` will not wait for this transfer: it keeps
--- downloading in the background while the caller resolves other dependencies,
--- and is collected later via `waitBackground()` (or by `finish()`).
---@param url string
---@param destPath string
---@return "pending"|"done"
function download.background(url, destPath)
	if not session then return "done" end
	if seedFromCache(destPath) then return "done" end
	local index = session.batch:add(url, { path = destPath, timeout = DOWNLOAD_TIMEOUT })
	session.pending[destPath] = index
	session.background[destPath] = true
	return "pending"
end

--- Block until every non-background prefetched download has completed.
function download.drain()
	if not session then return end
	pumpUntil(nil)
	for destPath in pairs(session.pending) do
		if not session.background[destPath] then resolveTransfer(destPath) end
	end
end

--- Block until a specific (typically background) transfer completes and
--- resolve it. Returns its result, or nil when no session is active.
---@param destPath string
---@return { ok: boolean, path: string, err: string? }?
function download.waitBackground(destPath)
	if not session then return nil end
	pumpUntil(destPath)
	resolveTransfer(destPath)
	return download.result(destPath)
end

--- Result of the prefetched download for `destPath` (after `drain()` /
--- `waitBackground()`).
---@param destPath string
---@return { ok: boolean, path: string, err: string? }?
function download.result(destPath)
	if not session then return nil end
	local res = session.pending[destPath]
	return type(res) == "table" and res or nil
end

return download
