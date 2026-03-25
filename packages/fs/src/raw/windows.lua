local ffi = require("ffi")

ffi.cdef([[
	typedef void* HANDLE;
	typedef uint32_t DWORD;
	typedef uint16_t WORD;
	typedef unsigned char BYTE;
	typedef int BOOL;
	typedef unsigned short WCHAR;

	typedef struct {
		DWORD dwLowDateTime;
		DWORD dwHighDateTime;
	} FILETIME;

	typedef struct {
		DWORD dwFileAttributes;
		FILETIME ftCreationTime;
		FILETIME ftLastAccessTime;
		FILETIME ftLastWriteTime;
		DWORD nFileSizeHigh;
		DWORD nFileSizeLow;
		DWORD dwReserved0;
		DWORD dwReserved1;
		char cFileName[260];
		char cAlternateFileName[14];
	} WIN32_FIND_DATAA;

	HANDLE FindFirstFileA(const char* lpFileName, WIN32_FIND_DATAA* lpFindFileData);
	BOOL FindNextFileA(HANDLE hFindFile, WIN32_FIND_DATAA* lpFindFileData);
	BOOL FindClose(HANDLE hFindFile);
	BOOL CreateDirectoryA(const char* lpPathName, void* lpSecurityAttributes);
	BOOL CreateSymbolicLinkA(const char* lpSymlinkFileName, const char* lpTargetFileName, DWORD dwFlags);
	DWORD GetFileAttributesA(const char* lpFileName);

	typedef struct {
		DWORD dwFileAttributes;
		FILETIME ftCreationTime;
		FILETIME ftLastAccessTime;
		FILETIME ftLastWriteTime;
		DWORD nFileSizeHigh;
		DWORD nFileSizeLow;
	} WIN32_FILE_ATTRIBUTE_DATA;

	BOOL GetFileAttributesExA(const char* lpFileName, int fInfoLevelClass, WIN32_FILE_ATTRIBUTE_DATA* lpFileInformation);

	HANDLE CreateFileA(
		const char* lpFileName,
		DWORD dwDesiredAccess,
		DWORD dwShareMode,
		void* lpSecurityAttributes,
		DWORD dwCreationDisposition,
		DWORD dwFlagsAndAttributes,
		HANDLE hTemplateFile
	);

	BOOL DeviceIoControl(
		HANDLE hDevice,
		DWORD dwIoControlCode,
		void* lpInBuffer,
		DWORD nInBufferSize,
		void* lpOutBuffer,
		DWORD nOutBufferSize,
		DWORD* lpBytesReturned,
		void* lpOverlapped
	);

	BOOL CloseHandle(HANDLE hObject);

	DWORD GetFullPathNameA(
		const char* lpFileName,
		DWORD nBufferLength,
		char* lpBuffer,
		char** lpFilePart
	);

	BOOL RemoveDirectoryA(const char* lpPathName);
	BOOL DeleteFileA(const char* lpFileName);
]])

local kernel32 = ffi.load("kernel32")

local INVALID_HANDLE_VALUE = ffi.cast("HANDLE", -1)
local INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF
local FILE_ATTRIBUTE_DIRECTORY = 0x10
local FILE_ATTRIBUTE_REPARSE_POINT = 0x400

---@class fs.raw.windows: fs.raw
local fs = {}

---@param p string
---@return (fun(): fs.DirEntry?)?
function fs.readdir(p)
	local searchPath = p .. "\\*"

	---@type { cFileName: string, dwFileAttributes: number }
	local findData = ffi.new("WIN32_FIND_DATAA")

	local handle = kernel32.FindFirstFileA(searchPath, findData)
	if handle == INVALID_HANDLE_VALUE then
		return nil
	end

	local first = true

	return function()
		while true do
			local hasNext
			if first then
				first = false
				hasNext = true
			else
				hasNext = kernel32.FindNextFileA(handle, findData) ~= 0
			end

			if not hasNext then
				kernel32.FindClose(handle)
				return nil
			end

			local name = ffi.string(findData.cFileName)
			if name ~= "." and name ~= ".." then
				local isDir = bit.band(findData.dwFileAttributes, FILE_ATTRIBUTE_DIRECTORY) ~= 0
				local isLink = bit.band(findData.dwFileAttributes, FILE_ATTRIBUTE_REPARSE_POINT) ~= 0

				local entryType
				if isLink then
					entryType = "symlink"
				elseif isDir then
					entryType = "dir"
				else
					entryType = "file"
				end

				return {
					name = name,
					type = entryType
				}
			end
		end
	end
end

---@param p string
---@return number?
local function getFileAttrs(p)
	local attrs = kernel32.GetFileAttributesA(p)
	if attrs == INVALID_FILE_ATTRIBUTES then
		return nil
	end
	return attrs
end

---@param p string
---@return boolean
function fs.exists(p)
	return getFileAttrs(p) ~= nil
end

---@param p string
function fs.isdir(p)
	local attrs = getFileAttrs(p)
	if attrs == nil then
		return false
	end

	return bit.band(attrs, FILE_ATTRIBUTE_DIRECTORY) ~= 0
end

---@param p string
function fs.mkdir(p)
	return kernel32.CreateDirectoryA(p, nil) ~= 0
end

local GENERIC_WRITE = 0x40000000
local OPEN_EXISTING = 3
local FILE_FLAG_BACKUP_SEMANTICS = 0x02000000
local FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000
local FSCTL_SET_REPARSE_POINT = 0x000900A4
local IO_REPARSE_TAG_MOUNT_POINT = 0xA0000003

--- Resolves a path to an absolute path using Win32 GetFullPathNameA.
---@param p string
---@return string?
local function getFullPath(p)
	local buf = ffi.new("char[?]", 1024)
	local len = kernel32.GetFullPathNameA(p, 1024, buf, nil)
	if len == 0 or len >= 1024 then
		return nil
	end
	return ffi.string(buf, len)
end

--- Creates an NTFS junction point (directory only).
--- Junctions do not require elevated privileges, unlike symlinks.
---@param src string # Target directory (must be absolute or will be resolved)
---@param dest string # Junction path to create
---@return boolean
local function createJunction(src, dest)
	-- Junctions require an absolute target path
	local absTarget = getFullPath(src)
	if not absTarget then
		return false
	end

	-- Create the junction directory
	if kernel32.CreateDirectoryA(dest, nil) == 0 then
		return false
	end

	-- Build the NT path: \??\C:\path\to\target
	local ntTarget = "\\??\\" .. absTarget

	-- Encode the target as UTF-16LE
	local ntTargetW = {} ---@type string[]
	for i = 1, #ntTarget do
		ntTargetW[#ntTargetW + 1] = string.sub(ntTarget, i, i) .. "\0"
	end
	local targetBytes = table.concat(ntTargetW)
	local targetByteLen = #targetBytes

	-- Build REPARSE_DATA_BUFFER for mount point (junction)
	-- Layout:
	--   DWORD ReparseTag
	--   WORD  ReparseDataLength
	--   WORD  Reserved
	--   WORD  SubstituteNameOffset
	--   WORD  SubstituteNameLength
	--   WORD  PrintNameOffset
	--   WORD  PrintNameLength
	--   WCHAR PathBuffer[...]  (SubstituteName + NUL + PrintName + NUL)
	local pathBufSize = targetByteLen + 2 + 2 -- substitute name + NUL + print name (empty) + NUL
	local reparseDataLen = 8 + pathBufSize -- 4 WORDs (8 bytes) + path buffer
	local totalSize = 8 + reparseDataLen   -- header (tag + length + reserved) + data

	local buf = ffi.new("uint8_t[?]", totalSize)
	local ptr = ffi.cast("uint8_t*", buf)

	-- ReparseTag (DWORD)
	ffi.cast("uint32_t*", ptr)[0] = IO_REPARSE_TAG_MOUNT_POINT
	-- ReparseDataLength (WORD)
	ffi.cast("uint16_t*", ptr + 4)[0] = reparseDataLen
	-- Reserved (WORD)
	ffi.cast("uint16_t*", ptr + 6)[0] = 0
	-- SubstituteNameOffset (WORD)
	ffi.cast("uint16_t*", ptr + 8)[0] = 0
	-- SubstituteNameLength (WORD) - without null terminator
	ffi.cast("uint16_t*", ptr + 10)[0] = targetByteLen
	-- PrintNameOffset (WORD) - after substitute name + null terminator
	ffi.cast("uint16_t*", ptr + 12)[0] = targetByteLen + 2
	-- PrintNameLength (WORD) - empty print name
	ffi.cast("uint16_t*", ptr + 14)[0] = 0

	-- PathBuffer: substitute name
	ffi.copy(ptr + 16, targetBytes, targetByteLen)
	-- Null terminator for substitute name (2 bytes)
	ffi.cast("uint16_t*", ptr + 16 + targetByteLen)[0] = 0
	-- Null terminator for print name (2 bytes)
	ffi.cast("uint16_t*", ptr + 16 + targetByteLen + 2)[0] = 0

	-- Open the junction directory with reparse point access
	local handle = kernel32.CreateFileA(
		dest,
		GENERIC_WRITE,
		0,
		nil,
		OPEN_EXISTING,
		FILE_FLAG_BACKUP_SEMANTICS + FILE_FLAG_OPEN_REPARSE_POINT,
		nil
	)

	if handle == INVALID_HANDLE_VALUE then
		kernel32.RemoveDirectoryA(dest)
		return false
	end

	local bytesReturned = ffi.new("DWORD[1]")
	local ok = kernel32.DeviceIoControl(
		handle,
		FSCTL_SET_REPARSE_POINT,
		buf,
		totalSize,
		nil,
		0,
		bytesReturned,
		nil
	)

	kernel32.CloseHandle(handle)

	if ok == 0 then
		kernel32.RemoveDirectoryA(dest)
		return false
	end

	return true
end

--- Removes a symlink or junction without following it.
---@param p string
---@return boolean
function fs.rmlink(p)
	local attrs = getFileAttrs(p)
	if attrs ~= nil and bit.band(attrs, FILE_ATTRIBUTE_DIRECTORY) ~= 0 then
		return kernel32.RemoveDirectoryA(p) ~= 0
	end
	return kernel32.DeleteFileA(p) ~= 0
end

---@param src string
---@param dest string
function fs.mklink(src, dest)
	if fs.isdir(src) then
		return createJunction(src, dest)
	end

	return kernel32.CreateSymbolicLinkA(dest, src, 0) ~= 0
end

---@param p string
function fs.islink(p)
	local attrs = getFileAttrs(p)
	if attrs == nil then
		return false
	end

	return bit.band(attrs, FILE_ATTRIBUTE_REPARSE_POINT) ~= 0
end

---@param p string
function fs.isfile(p)
	local attrs = getFileAttrs(p)
	if attrs == nil then
		return false
	end

	return bit.band(attrs, FILE_ATTRIBUTE_DIRECTORY) == 0 and bit.band(attrs, FILE_ATTRIBUTE_REPARSE_POINT) == 0
end

-- FILETIME is 100ns intervals since 1601-01-01. Unix epoch is 1970-01-01.
-- Difference: 11644473600 seconds = 116444736000000000 in 100ns units.
local EPOCH_DIFF = 116444736000000000ULL

---@param ft { dwLowDateTime: number, dwHighDateTime: number }
local function filetimeToUnix(ft)
	local ticks = ffi.cast("uint64_t", ft.dwHighDateTime) * 0x100000000ULL + ft.dwLowDateTime
	return tonumber((ticks - EPOCH_DIFF) / 10000000ULL)
end

---@param attrs number
---@return fs.Stat.Type
local function attrsToType(attrs)
	if bit.band(attrs, FILE_ATTRIBUTE_REPARSE_POINT) ~= 0 then
		return "symlink"
	elseif bit.band(attrs, FILE_ATTRIBUTE_DIRECTORY) ~= 0 then
		return "dir"
	else
		return "file"
	end
end

---@class fs.raw.windows.Stat
---@field dwFileAttributes number
---@field ftLastAccessTime { dwLowDateTime: number, dwHighDateTime: number }
---@field ftLastWriteTime { dwLowDateTime: number, dwHighDateTime: number }
---@field nFileSizeHigh number
---@field nFileSizeLow number

---@type fun(): fs.raw.windows.Stat
---@diagnostic disable-next-line: assign-type-mismatch
local newFileAttrData = ffi.typeof("WIN32_FILE_ATTRIBUTE_DATA")

---@param s fs.raw.windows.Stat
local function fileSize(s)
	return tonumber(s.nFileSizeHigh) * 0x100000000 + tonumber(s.nFileSizeLow)
end

---@param s fs.raw.windows.Stat
---@param type fs.Stat.Type
---@return fs.Stat
local function rawToCrossStat(s, type)
	return {
		size = fileSize(s),
		accessTime = filetimeToUnix(s.ftLastAccessTime),
		modifyTime = filetimeToUnix(s.ftLastWriteTime),
		type = type
	}
end

---@param p string
---@return fs.Stat?
function fs.stat(p)
	local data = newFileAttrData()
	if kernel32.GetFileAttributesExA(p, 0, data) == 0 then
		return nil
	end

	local type = bit.band(data.dwFileAttributes, FILE_ATTRIBUTE_DIRECTORY) ~= 0 and "dir" or "file"
	return rawToCrossStat(data, type)
end

---@param p string
---@return fs.Stat?
function fs.lstat(p)
	local data = newFileAttrData()
	if kernel32.GetFileAttributesExA(p, 0, data) == 0 then
		return nil
	end

	return rawToCrossStat(data, attrsToType(data.dwFileAttributes))
end

return fs
