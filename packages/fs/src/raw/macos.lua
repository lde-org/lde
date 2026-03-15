local ffi = require("ffi")

ffi.cdef([[
	struct timespec {
		long tv_sec;
		long tv_nsec;
	};

	struct stat {
		int32_t         st_dev;
		uint16_t        st_mode;
		uint16_t        st_nlink;
		uint64_t        st_ino;
		uint32_t        st_uid;
		uint32_t        st_gid;
		int32_t         st_rdev;
		struct timespec st_atimespec;
		struct timespec st_mtimespec;
		struct timespec st_ctimespec;
		struct timespec st_birthtimespec;
		int64_t         st_size;
		int64_t         st_blocks;
		int32_t         st_blksize;
		uint32_t        st_flags;
		uint32_t        st_gen;
		int32_t         st_lspare;
		int64_t         st_qspare[2];
	};

	struct dirent {
		uint64_t d_ino;
		uint64_t d_seekoff;
		uint16_t d_reclen;
		uint16_t d_namlen;
		uint8_t  d_type;
		char     d_name[1024];
	};
]])

---@class fs.raw.macos: fs.raw.posix
return require("fs.raw.posix")(function(s, modeToStatType)
	return {
		size = s.st_size,
		modifyTime = s.st_mtimespec.tv_sec,
		accessTime = s.st_atimespec.tv_sec,
		type = modeToStatType[bit.band(s.st_mode, 0xF000)],
		mode = bit.band(s.st_mode, 0x1FF),
	}
end)
