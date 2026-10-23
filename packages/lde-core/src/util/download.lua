const fs = require("fs")
local ffi = require("ffi")
local path = require("path")
const util = require("util")
const consts = require("lde-core.global.consts")

const curl = util.lazy(|| -> require("curl-sys"))

-- Short wait while a concurrent process releases a handle we need.
local sleep
if jit.os == "Windows" then
	pcall(ffi.cdef, "void Sleep(unsigned int ms);")
	sleep = function(ms) ffi.C.Sleep(ms) end
else
	pcall(ffi.cdef, "int usleep(unsigned int usec);")
	sleep = function(ms) ffi.C.usleep(ms * 1000) end
end

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
		-- The batch writes straight to the path it is handed, so an in-flight
		-- download goes to a path private to this process and is renamed into
		-- place once complete: two installs fetching the same URL (parallel test
		-- shards, two terminals) would otherwise interleave writes and both
		-- extract a truncated file.
		token = tostring({}):match("0x(%x+)$") or tostring(os.time()),
		parts = 0,
		partFor = {},
	}
end

---@param dropParts boolean # true when in-flight downloads are being abandoned
local function close(dropParts)
	if dropParts then
		for _, part in pairs(session.partFor) do fs.delete(part) end
	end
	session.batch:close()
	session = nil
end

function download.finish()
	if not session then return end
	session.batch:runAll()
	close(true)
end

function download.abort()
	if not session then return end
	close(true)
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
	const part = session.partFor[destPath]
	session.partFor[destPath] = nil
	if res.ok and part then
		-- Rename, not copy: a reader (another process, or this one) must only ever
		-- see the complete file at destPath.
		fs.mkdirAll(path.dirname(destPath))
		local moveErr
		if not fs.exists(destPath) then
			-- A failed move is not a failed download: another process may have renamed
			-- its own part into place between the check and the move (Windows refuses
			-- that with a sharing violation), or a scanner may briefly hold the freshly
			-- written part. Its bytes are identical, so the part is dropped and the
			-- winner's file is used. Retried because the handle is released shortly.
			for attempt = 1, 100 do
				local moved
				moved, moveErr = fs.move(part, destPath)
				if moved or fs.exists(destPath) then break end
				if attempt % 4 == 0 then sleep(20) end
			end
			-- A scanner can hold the freshly written part for longer than that. The
			-- bytes are complete either way, so copy instead of renaming: reading a
			-- held file is allowed, renaming it is not.
			if not fs.exists(destPath) then
				if fs.copy(part, destPath) then moveErr = nil end
			end
		end
		fs.delete(part)
		if not fs.exists(destPath) then
			res.ok = false
			res.err = "could not move download into place: " .. destPath
				.. (moveErr and (" (" .. tostring(moveErr) .. ")") or "")
		end
	end
	if not res.ok and part then fs.delete(part) end
	if res.ok and session.archiveCache then
		local cached = path.join(session.archiveCache, path.basename(destPath))
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

--- The path this session downloads `destPath` through: private to the process, and
--- stable for the session so a retry reuses it instead of leaving another leftover.
---@param destPath string
local function partPath(destPath) ---@cast session -nil
	local part = session.partFor[destPath]
	if part then return part end
	session.parts += 1
	part = destPath .. ".part-" .. session.token .. "-" .. tostring(session.parts)
	session.partFor[destPath] = part
	return part
end

--- A file at `destPath` is always complete: downloads land in a private part path and
--- are renamed into place, so nothing partial ever appears there. It is trusted as-is
--- — deleting it (as an interrupted run's leftover) would race a concurrent process
--- that is about to extract the very file it just renamed in.
---@param destPath string
---@return boolean
local function seedFromCache(destPath) ---@cast session -nil
	if fs.exists(destPath) then
		return true
	end
	if not session.archiveCache then return false end
	local cached = path.join(session.archiveCache, path.basename(destPath))
	if not fs.exists(cached) then return false end
	-- Copied through the same private path, so an interrupted seed cannot leave a
	-- partial file where every later run would trust it.
	const part = partPath(destPath)
	fs.mkdirAll(path.dirname(destPath))
	fs.copy(cached, part)
	const moved = fs.move(part, destPath)
	if not moved then
		fs.delete(part)
		return false
	end
	return true
end

--- Called after a download turns out to be unusable (extraction or checksum failure):
--- neither the file nor the user-level copy may be trusted again, or every later run
--- re-fails on the same bytes. Safe against concurrent runs: a healthy download is
--- never invalidated, since only the process that hit the failure calls this.
---@param destPath string
function download.invalidate(destPath)
	fs.delete(destPath)
	if session and session.archiveCache then
		fs.delete(path.join(session.archiveCache, path.basename(destPath)))
	end
end

---@param url string
---@param destPath string
---@return "pending"|"done"
function download.prefetch(url, destPath)
	if not session then return "done" end
	if seedFromCache(destPath) then return "done" end
	local index = session.batch:add(url, { path = partPath(destPath), timeout = consts.DOWNLOAD_TIMEOUT })
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
	local index = session.batch:add(url, { path = partPath(destPath), timeout = consts.DOWNLOAD_TIMEOUT })
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
