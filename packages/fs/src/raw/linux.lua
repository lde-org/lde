local ffi = require("ffi")

if jit.arch == "x64" then
	ffi.cdef([[
		struct stat {
			unsigned long st_dev;
			unsigned long st_ino;
			unsigned long st_nlink;
			unsigned int  st_mode;
			unsigned int  st_uid;
			unsigned int  st_gid;
			unsigned int  __pad0;
			unsigned long st_rdev;
			long          st_size;
			long          st_blksize;
			long          st_blocks;
			unsigned long st_atime;
			unsigned long st_atime_nsec;
			unsigned long st_mtime;
			unsigned long st_mtime_nsec;
			unsigned long st_ctime;
			unsigned long st_ctime_nsec;
			long          __unused[3];
		};
	]])
elseif jit.arch == "arm64" then
	ffi.cdef([[
		struct stat {
			unsigned long st_dev;
			unsigned long st_ino;
			unsigned int  st_mode;
			unsigned int  st_nlink;
			unsigned int  st_uid;
			unsigned int  st_gid;
			unsigned long st_rdev;
			unsigned long __pad1;
			long          st_size;
			int           st_blksize;
			int           __pad2;
			long          st_blocks;
			long          st_atime;
			unsigned long st_atime_nsec;
			long          st_mtime;
			unsigned long st_mtime_nsec;
			long          st_ctime;
			unsigned long st_ctime_nsec;
			unsigned int  __unused[2];
		};
	]])
else
	error("Unsupported architecture: " .. jit.arch)
end

ffi.cdef([[
	struct dirent {
		unsigned long  d_ino;
		unsigned long  d_off;
		unsigned short d_reclen;
		unsigned char  d_type;
		char           d_name[256];
	};
]])

pcall(ffi.cdef, [[
	int inotify_init1(int flags);
	int inotify_add_watch(int fd, const char* pathname, uint32_t mask);
	int inotify_rm_watch(int fd, int wd);
	long read(int fd, void* buf, size_t count);
	int close(int fd);
]])

local IN_CREATE     = 0x00000100
local IN_DELETE     = 0x00000200
local IN_MODIFY     = 0x00000002
local IN_MOVED_FROM = 0x00000040
local IN_MOVED_TO   = 0x00000080
local IN_NONBLOCK   = 0x800

pcall(ffi.cdef, [[
	int fcntl(int fd, int cmd, ...);
]])
local F_GETFL = 3
local F_SETFL = 4
local O_NONBLOCK = 0x800

---@class fs.raw.linux: fs.raw.posix
local fs            = require("fs.raw.posix")(function(s, modeToStatType)
	return {
		size = s.st_size,
		modifyTime = s.st_mtime,
		accessTime = s.st_atime,
		type = modeToStatType[bit.band(s.st_mode, 0xF000)],
		mode = bit.band(s.st_mode, 0x1FF)
	}
end)

---@alias fs.WatchEvent "create" | "modify" | "delete" | "rename"

---@class fs.Watcher
---@field close fun()
---@field poll fun()
---@field wait fun()

--- Watch a path for changes. Calls callback(event, name) for each change.
--- Returns a watcher with :poll() (non-blocking), :wait() (blocking), and :close().
---@param p string
---@param callback fun(event: fs.WatchEvent, name: string)
---@param opts { recursive: boolean? }?
---@return fs.Watcher?
function fs.watch(p, callback, opts)
	local recursive = opts and opts.recursive or false

	local ifd = ffi.C.inotify_init1(IN_NONBLOCK)
	if ifd < 0 then return nil end

	local mask = bit.bor(IN_CREATE, IN_DELETE, IN_MODIFY, IN_MOVED_FROM, IN_MOVED_TO)

	-- wd -> absolute dir path, for resolving event names in recursive mode
	local wdPaths = {} ---@type table<number, string>

	local function addWatch(dir)
		local wd = ffi.C.inotify_add_watch(ifd, dir, mask)
		if wd >= 0 then wdPaths[tonumber(wd)] = dir end
		return wd
	end

	if addWatch(p) < 0 then
		ffi.C.close(ifd)
		return nil
	end

	if recursive then
		local function walkDirs(dir)
			local iter = fs.readdir(dir)
			if not iter then return end
			for entry in iter do
				if entry.type == "dir" then
					local sub = dir .. "/" .. entry.name
					addWatch(sub)
					walkDirs(sub)
				end
			end
		end
		walkDirs(p)
	end

	local bufSize = 4096
	local buf = ffi.new("uint8_t[?]", bufSize)

	local function drain()
		local n = ffi.C.read(ifd, buf, bufSize)
		if n <= 0 then return end

		local i = 0
		while i < n do
			local ptr = buf + i
			local wd      = ffi.cast("int32_t*",  ptr)[0]
			local evMask  = ffi.cast("uint32_t*", ptr + 4)[0]
			local nameLen = ffi.cast("uint32_t*", ptr + 12)[0]
			local name    = nameLen > 0 and ffi.string(ptr + 16) or ""

			-- In recursive mode, prefix name with the relative subdir path
			if recursive and wdPaths[tonumber(wd)] and wdPaths[tonumber(wd)] ~= p then
				local rel = string.sub(wdPaths[tonumber(wd)], #p + 2)
				name = rel .. "/" .. name
			end

			local event ---@type fs.WatchEvent
			if bit.band(evMask, IN_CREATE) ~= 0 then
				event = "create"
				-- Watch newly created subdirectories
				if recursive and bit.band(evMask, 0x40000000) ~= 0 then -- IN_ISDIR
					local newDir = wdPaths[tonumber(wd)] .. "/" .. (nameLen > 0 and ffi.string(ptr + 16) or "")
					addWatch(newDir)
				end
			elseif bit.band(evMask, IN_DELETE) ~= 0 then
				event = "delete"
			elseif bit.band(evMask, IN_MODIFY) ~= 0 then
				event = "modify"
			elseif bit.band(evMask, bit.bor(IN_MOVED_FROM, IN_MOVED_TO)) ~= 0 then
				event = "rename"
			end

			if event then callback(event, name) end
			i = i + 16 + nameLen
		end
	end

	---@type fs.Watcher
	local watcher = {}

	function watcher.poll()
		drain()
	end

	function watcher.wait()
		local flags = ffi.C.fcntl(ifd, F_GETFL)
		ffi.C.fcntl(ifd, F_SETFL, bit.band(flags, bit.bnot(O_NONBLOCK)))
		drain()
		ffi.C.fcntl(ifd, F_SETFL, flags)
	end

	function watcher.close()
		for wd in pairs(wdPaths) do
			ffi.C.inotify_rm_watch(ifd, wd)
		end
		ffi.C.close(ifd)
	end

	return watcher
end

return fs
