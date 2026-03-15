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

---@class fs.raw.linux: fs.raw.posix
return require("fs.raw.posix")(function(s, modeToStatType)
	return {
		size = s.st_size,
		modifyTime = s.st_mtime,
		accessTime = s.st_atime,
		type = modeToStatType[bit.band(s.st_mode, 0xF000)],
		mode = bit.band(s.st_mode, 0x1FF),
	}
end)
