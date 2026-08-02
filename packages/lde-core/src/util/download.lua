local curl = require("curl-sys")
local fs = require("fs")

--- Parallel download session used during dependency installation.
---
--- The install resolver discovers the dependency graph level by level. For
--- each level it prefetches every known source (`.src.rock` files, rockspecs,
--- git tarballs) into the local caches *in parallel*, then `drain()`s the
--- batch. The sequential resolution work that follows therefore hits the
--- cache instead of the network.
---
--- Outside of an active session (`download.active()` == false) everything
--- falls back to the plain synchronous `curl.*` calls, so non-install paths
--- (e.g. `lde install --git`, bundling, `ensureMingw`) are unaffected.

local download = {}

---@class download.Session
---@field batch CurlBatch
---@field pending table<string, integer>  destPath -> batch transfer index
---@field progress fun(done: integer, total: integer)?

local session = nil

--- Start a parallel download session. Blocks until everything finishes.
---@param opts table?  -- { progress: fun(done, total)? }
function download.begin(opts)
	assert(not session, "download session already active")
	session = {
		batch = curl.batch({ progress = opts and opts.progress or nil }),
		pending = {},
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

--- Block until every prefetched download in the session has completed.
function download.drain()
	if not session then return end
	local results = session.batch:runAll()
	for destPath, index in pairs(session.pending) do
		session.pending[destPath] = results[index] or { ok = false, err = "missing result" }
	end
end

--- Result of the prefetched download for `destPath` (after `drain()`).
---@param destPath string
---@return { ok: boolean, path: string, err: string? }?
function download.result(destPath)
	if not session then return nil end
	local res = session.pending[destPath]
	return type(res) == "table" and res or nil
end

return download
