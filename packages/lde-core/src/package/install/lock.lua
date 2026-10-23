--- Cross-process build lock. A directory is the lock (mkdir is atomic on every
--- platform), so two `lde install` runs that build the same cached rock into the
--- same directory serialize instead of deleting each other's output mid-link.

const fs = require("fs")
const ffi = require("ffi")
local path = require("path")

-- A holder killed without releasing must not wedge the cache forever: a lock
-- whose heartbeat is older than this is stolen.
const STALE_SECONDS = 120

local lock = {}

local sleep
if jit.os == "Windows" then
	pcall(ffi.cdef, "void Sleep(unsigned long dwMilliseconds);")
	sleep = function(ms) ffi.C.Sleep(ms) end
else
	pcall(ffi.cdef, "int usleep(unsigned int usec);")
	sleep = function(ms) ffi.C.usleep(ms * 1000) end
end

---@class lde.install.Lock
---@field dir string

---@param lockDir string
local function heartbeatPath(lockDir) return path.join(lockDir, "time") end

---@param lockDir string
local function isStale(lockDir)
	local beat = tonumber(fs.read(heartbeatPath(lockDir)) or "")
	if beat then return (os.time() - beat) > STALE_SECONDS end
	const stat = fs.stat(lockDir)
	return stat ~= nil and (os.time() - stat.modifyTime) > STALE_SECONDS
end

--- Waits for the lock guarding `target`, then holds it until release().
---@param target string # directory whose build is serialized
---@param opts { createParent: boolean? }? # false: never create the parent chain (a cache dir being retired must not be resurrected); returns nil when it is missing
---@return lde.install.Lock?
function lock.acquire(target, opts)
	const lockDir = target .. ".lde-lock"
	if opts and opts.createParent == false then
		-- A missing parent means the tree was retired: creating it would leave an
		-- empty cache entry that resolution would later trust. Nothing to hold.
		if not fs.isdir(path.dirname(lockDir)) then return nil end
	else
		fs.mkdirAll(path.dirname(lockDir))
	end
	const startedAt = os.time()
	while true do
		if fs.mkdir(lockDir) then
			const handle = { dir = lockDir }
			lock.touch(handle)
			return handle
		end
		if isStale(lockDir) then
			fs.rmdir(lockDir)
		elseif (os.time() - startedAt) > STALE_SECONDS then
			-- Never hang on a lock we cannot take: the build reports real
			-- conflicts itself, and a stuck install is worse than a racy one.
			return nil
		else
			sleep(5)
		end
	end
end

--- Keeps the lock fresh so a long build is not stolen by a waiting process.
---@param handle lde.install.Lock?
function lock.touch(handle)
	if handle then fs.write(heartbeatPath(handle.dir), tostring(os.time())) end
end

---@param handle lde.install.Lock?
function lock.release(handle)
	if handle then fs.rmdir(handle.dir) end
end

return lock
