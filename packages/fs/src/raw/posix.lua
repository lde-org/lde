local ffi = require("ffi")

ffi.cdef([[
	typedef struct __dirstream DIR;
	DIR* opendir(const char* name);
	int closedir(DIR* dirp);
	int mkdir(const char* pathname, unsigned int mode);
	int symlink(const char* target, const char* linkpath);
	int chmod(const char* pathname, unsigned int mode);
]])

---@type table<number, fs.DirEntry.Type>
local dTypeToEntryType = {
	[0] = "unknown",
	[4] = "dir",
	[8] = "file",
	[10] = "symlink"
}

---@type table<number, fs.Stat.Type>
local modeToStatType = {
	[0x4000] = "dir",
	[0x8000] = "file",
	[0xA000] = "symlink"
}

--- Call after defining struct dirent and struct stat in ffi.
---@param rawToCrossStat fun(s: ffi.cdata*, modeToStatType: table<number, fs.Stat.Type>): fs.Stat
---@return fs.raw.posix
return function(rawToCrossStat)
	ffi.cdef([[
		struct dirent* readdir(DIR* dirp);
		int stat(const char* pathname, struct stat* statbuf);
		int lstat(const char* pathname, struct stat* statbuf);
	]])

	---@class fs.raw.posix: fs.raw
	local fs = {}

	local newStat = ffi.typeof("struct stat")

	local function rawStat(p)
		local buf = newStat()
		if ffi.C.stat(p, buf) ~= 0 then return nil end
		return buf
	end

	local function rawLstat(p)
		local buf = newStat()
		if ffi.C.lstat(p, buf) ~= 0 then return nil end
		return buf
	end

	---@param p string
	---@return (fun(): fs.DirEntry?)?
	function fs.readdir(p)
		local dir = ffi.C.opendir(p)
		if dir == nil then return nil end

		return function()
			while true do
				local entry = ffi.C.readdir(dir)
				if entry == nil then
					ffi.C.closedir(dir)
					return nil
				end

				local name = ffi.string(entry.d_name)
				if name ~= "." and name ~= ".." then
					return {
						name = name,
						type = dTypeToEntryType[entry.d_type] or "unknown"
					}
				end
			end
		end
	end

	---@param p string
	function fs.exists(p)
		return rawStat(p) ~= nil
	end

	---@param p string
	function fs.stat(p)
		local s = rawStat(p)
		if s == nil then return nil end
		return rawToCrossStat(s, modeToStatType)
	end

	---@param p string
	function fs.lstat(p)
		local s = rawLstat(p)
		if s == nil then return nil end
		return rawToCrossStat(s, modeToStatType)
	end

	---@param p string
	function fs.isdir(p)
		local s = rawStat(p)
		if s == nil then return false end
		return bit.band(s.st_mode, 0x4000) ~= 0
	end

	---@param p string
	function fs.isfile(p)
		local s = rawStat(p)
		if s == nil then return false end
		return bit.band(s.st_mode, 0x8000) ~= 0
	end

	---@param p string
	function fs.islink(p)
		local s = rawLstat(p)
		if s == nil then return false end
		return bit.band(s.st_mode, 0xA000) ~= 0
	end

	---@param p string
	function fs.mkdir(p)
		return ffi.C.mkdir(p, 511) == 0
	end

	---@param src string
	---@param dest string
	function fs.mklink(src, dest)
		return ffi.C.symlink(src, dest) == 0
	end

	---@param p string
	function fs.rmlink(p)
		return os.remove(p) ~= nil
	end

	---@param p string
	---@param mode number
	function fs.chmod(p, mode)
		return ffi.C.chmod(p, mode) == 0
	end

	return fs
end
