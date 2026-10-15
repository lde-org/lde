const fs = require("fs")
local path = require("path")
const util = require("util")

const curl = util.lazy(|| -> require("curl-sys"))

--- Parallel download session for installs: the resolver prefetches a whole level in
--- parallel so the sequential work that follows hits the cache. Without a session,
--- every call falls back to synchronous `curl.*`.

const download = {}

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

---@param opts table?  -- { progress: fun(done, total)?, archiveCache: string? }
function download.begin(opts)
	assert(not session, "download session already active")
	session = {
		batch = curl().batch({ progress = opts?.progress }) --[[@as download.Batch]],
		pending = {},
		background = {},
		archiveCache = opts?.archiveCache,
	}
end

function download.finish()
	if not session then return end
	session.batch:runAll()
	session.batch:close()
	session = nil
end

function download.abort()
	if not session then return end
	session.batch:close()
	session = nil
end

function download.active()
	return session ~= nil
end

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

--- Persist successful content into the user-level archive cache so future trees can seed from it instead of re-downloading.
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
			-- Copy to a temp name and rename: an interrupted copy must not leave a partial file that later runs trust as a full download.
			fs.mkdirAll(path.dirname(cached))
			local tmp = cached .. ".tmp"
			fs.copy(res.path, tmp)
			fs.move(tmp, cached)
		end
	end
end

---@param waitFor string?
local function pumpUntil(waitFor)
	if not session then return end
	while true do
		if waitFor ~= nil then
			if transferDone(waitFor) then return end
		elseif not pendingNonBackground() then
			return
		end
		const running = session.batch:pump()
		if running > 0 then session.batch:wait(10) end
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

--- Used to pipeline work under the download tail.
---@param fn fun(destPath: string)?
function download.onTransfer(fn)
	if session then session.onTransfer = fn end
end

--- A server that accepts the connection but never finishes the body would block the batch forever (curl-sys applies no default timeout).
const DOWNLOAD_TIMEOUT = 120 -- seconds

--- A file at `destPath` is trusted only when this session registered it or the
--- user-level archive cache backs it (both written after a successful transfer);
--- a leftover from an interrupted run is partial and is deleted to force a re-fetch.
---@param destPath string
---@return boolean
local function seedFromCache(destPath) ---@cast session -nil
	if fs.exists(destPath) then
		if type(session.pending[destPath]) == "number" then return true end
		local cached = session.archiveCache and path.join(session.archiveCache, path.basename(destPath))
		if cached and fs.exists(cached) then
			-- The leftover may be a partial download from an interrupted run; reseed from the complete copy instead of trusting it.
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

--- Called after extraction of seeded content fails: the copy may itself be corrupt and must not be re-trusted (and re-failed) on the next run.
---@param destPath string
function download.invalidateUserCache(destPath)
	if not session or not session.archiveCache then return end
	fs.delete(path.join(session.archiveCache, path.basename(destPath)))
end

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

--- Like `prefetch`, but `drain()` will not wait for this transfer; collected later via `waitBackground()` (or by `finish()`).
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

function download.drain()
	if not session then return end
	pumpUntil(nil)
	for destPath in pairs(session.pending) do
		if not session.background[destPath] then resolveTransfer(destPath) end
	end
end

---@param destPath string
---@return { ok: boolean, path: string, err: string? }?
function download.waitBackground(destPath)
	if not session then return nil end
	pumpUntil(destPath)
	resolveTransfer(destPath)
	return download.result(destPath)
end

---@param destPath string
---@return { ok: boolean, path: string, err: string? }?
function download.result(destPath)
	if not session then return nil end
	local res = session.pending[destPath]
	return type(res) == "table" ? res : nil
end

return download
