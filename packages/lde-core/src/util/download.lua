local fs = require("fs")
local util = require("util")

local curl = util.lazy(function() return require("curl-sys") end)

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

---@class download.Session
---@field batch CurlBatch
---@field pending table<string, integer|table>  destPath -> batch transfer index (a result table once resolved)
---@field background table<string, boolean>  destPath -> true for transfers drain() must not block on
---@field progress fun(done: integer, total: integer)?

local session = nil

--- Start a parallel download session. Blocks until everything finishes.
---@param opts table?  -- { progress: fun(done, total)? }
function download.begin(opts)
	assert(not session, "download session already active")
	session = {
		batch = curl().batch({ progress = opts and opts.progress or nil }),
		pending = {},
		background = {},
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
local function transferDone(destPath)
	local index = session.pending[destPath]
	if type(index) ~= "number" then return true end
	local res = session.batch:results()[index]
	return res ~= nil and res.err ~= "transfer not finished"
end

---@return boolean true when any non-background transfer is still running
local function pendingNonBackground()
	for destPath, index in pairs(session.pending) do
		if type(index) == "number" and not session.background[destPath] then
			if not transferDone(destPath) then return true end
		end
	end
	return false
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
	end
end

--- Resolve a finished transfer's pending entry into its result table.
---@param destPath string
local function resolveTransfer(destPath)
	local index = session.pending[destPath]
	if type(index) ~= "number" then return end
	local res = session.batch:results()[index] or { ok = false, err = "missing result" }
	session.pending[destPath] = res
	session.background[destPath] = nil
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
	local index = session.batch:add(url, { path = destPath })
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
	local index = session.batch:add(url, { path = destPath })
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
