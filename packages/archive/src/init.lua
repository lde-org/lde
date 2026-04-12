---@diagnostic disable: assign-type-mismatch

local ffi     = require("ffi")
local buf     = require("string.buffer")
local deflate = require("deflate-sys")
local fs      = require("fs")
local path    = require("path")

ffi.cdef [[
  typedef struct __attribute__((packed)) {
    uint32_t sig; uint16_t ver, flags, method, mtime, mdate;
    uint32_t crc, compSize, uncompSize;
    uint16_t nameLen, extraLen;
  } ZipLocal;

  typedef struct __attribute__((packed)) {
    uint32_t sig; uint16_t verMade, verNeed, flags, method, mtime, mdate;
    uint32_t crc, compSize, uncompSize;
    uint16_t nameLen, extraLen, commentLen, disk, iattr;
    uint32_t eattr, offset;
  } ZipCD;

  typedef struct __attribute__((packed)) {
    uint32_t sig; uint16_t disk, diskCd, count, total;
    uint32_t cdSize, cdOffset;
    uint16_t commentLen;
  } ZipEOCD;

  typedef struct __attribute__((packed)) {
    char name[100], mode[8], uid[8], gid[8], size[12], mtime[12],
         checksum[8], typeflag, linkname[100], magic[6], version[2],
         uname[32], gname[32], devmajor[8], devminor[8], prefix[155], pad[12];
  } TarHeader;
]]

---@class ZipLocal: ffi.cdata*
---@field sig       number
---@field ver       number
---@field flags     number
---@field method    number
---@field crc       number
---@field compSize  number
---@field uncompSize number
---@field nameLen   number
---@field extraLen  number

---@class ZipCD: ffi.cdata*
---@field sig        number
---@field crc        number
---@field compSize   number
---@field uncompSize number
---@field nameLen    number
---@field extraLen   number
---@field commentLen number
---@field method     number
---@field offset     number

---@class ZipEOCD: ffi.cdata*
---@field sig      number
---@field count    number
---@field total    number
---@field cdSize   number
---@field cdOffset number

---@class TarHeader: ffi.cdata*
---@field name     string
---@field mode     string
---@field size     string
---@field mtime    string
---@field checksum string
---@field typeflag number
---@field magic    string
---@field version  string

---@type fun(...): ZipLocal
local ZipLocalT  = ffi.typeof("ZipLocal")
---@type fun(...): ZipCD
local ZipCDT     = ffi.typeof("ZipCD")
---@type fun(...): ZipEOCD
local ZipEOCDT   = ffi.typeof("ZipEOCD")
---@type fun(): TarHeader
local TarHeaderT = ffi.typeof("TarHeader")

local tarHeaderSize = ffi.sizeof("TarHeader")

---@param dir string
local function mkdirp(dir)
	if fs.isdir(dir) then return end
	mkdirp(path.dirname(dir))
	fs.mkdir(dir)
end

---@param base    string
---@param name    string
---@param content string
local function writeFile(base, name, content)
	local out = path.join(base, name)
	mkdirp(path.dirname(out))
	fs.write(out, content)
end

-- ── ZIP extract ───────────────────────────────────────────────────────────────

---@param data   string
---@param toPath string
---@param strip  boolean
local function zipExtract(data, toPath, strip)
	local dptr   = ffi.cast("const uint8_t *", data)
	local eocdOff = #data - 22
	while eocdOff >= 0 and ffi.cast("ZipEOCD *", dptr + eocdOff).sig ~= 0x06054b50 do
		eocdOff = eocdOff - 1
	end
	assert(eocdOff >= 0, "ZIP: EOCD not found")
	---@type ZipEOCD
	local eocd = ffi.cast("ZipEOCD *", dptr + eocdOff)
	local cd   = ffi.cast("const uint8_t *", dptr + eocd.cdOffset)

	for _ = 1, eocd.total do
		---@type ZipCD
		local e = ffi.cast("ZipCD *", cd)
		assert(e.sig == 0x02014b50, "ZIP: bad CD entry")
		local name = ffi.string(cd + ffi.sizeof("ZipCD"), e.nameLen)
		if strip then name = name:match("^[^/]*/(.+)") or name end
		if name:sub(-1) ~= "/" then
			---@type ZipLocal
			local lh      = ffi.cast("ZipLocal *", dptr + e.offset)
			local raw     = ffi.string(dptr + e.offset + ffi.sizeof("ZipLocal") + lh.nameLen + lh.extraLen, e.compSize)
			local content = e.method == 0 and raw or deflate.deflateDecompress(raw, e.uncompSize)
			writeFile(toPath, name, content)
		else
			fs.mkdir(path.join(toPath, name))
		end
		cd = cd + ffi.sizeof("ZipCD") + e.nameLen + e.extraLen + e.commentLen
	end
end

-- ── ZIP save ──────────────────────────────────────────────────────────────────

---@param files  table<string, string>
---@param toPath string
local function zipSave(files, toPath)
	local out   = buf.new()
	local cdBuf = buf.new()
	local offset, count = 0, 0

	for name, content in pairs(files) do
		local comp = deflate.deflateCompress(content, 6)
		local crc  = deflate.crc32(content)

		local lh = ZipLocalT(0x04034b50, 20, 0, 8, 0, 0, crc, #comp, #content, #name, 0)
		out:putcdata(lh, ffi.sizeof(lh)); out:put(name, comp)

		local cd = ZipCDT(0x02014b50, 20, 20, 0, 8, 0, 0, crc, #comp, #content, #name, 0, 0, 0, 0, 0, offset)
		cdBuf:putcdata(cd, ffi.sizeof(cd)); cdBuf:put(name)

		offset = offset + ffi.sizeof(lh) + #name + #comp
		count  = count + 1
	end

	local cdStr = cdBuf:tostring()
	local eocd  = ZipEOCDT(0x06054b50, 0, 0, count, count, #cdStr, offset, 0)
	out:put(cdStr); out:putcdata(eocd, ffi.sizeof(eocd))
	return fs.write(toPath, out:tostring())
end

-- ── TAR extract ───────────────────────────────────────────────────────────────

---@param data   string
---@param toPath string
---@param strip  boolean
local function tarExtract(data, toPath, strip)
	local dptr = ffi.cast("const uint8_t *", data)
	local pos  = 0
	while pos + tarHeaderSize <= #data do
		---@type TarHeader
		local h = ffi.cast("TarHeader *", dptr + pos)
		if h.name[0] == 0 then break end
		local name = ffi.string(h.name)
		local size = tonumber(ffi.string(h.size, 11), 8) or 0
		pos = pos + tarHeaderSize
		if strip then name = name:match("^[^/]*/(.+)") or name end
		if h.typeflag == string.byte("5") or name:sub(-1) == "/" then
			fs.mkdir(path.join(toPath, name))
		elseif h.typeflag == string.byte("0") or h.typeflag == 0 then
			writeFile(toPath, name, ffi.string(dptr + pos, size))
		end
		pos = pos + math.ceil(size / 512) * 512
	end
end

-- ── TAR save ─────────────────────────────────────────────────────────────────

---@param files  table<string, string>
---@param toPath string
local function tarSave(files, toPath)
	local out = buf.new()
	for name, content in pairs(files) do
		---@type TarHeader
		local h = TarHeaderT()
		ffi.copy(h.name,     name,                             math.min(#name, 100))
		ffi.copy(h.mode,     "0000644\0",                      8)
		ffi.copy(h.size,     string.format("%011o", #content), 11)
		ffi.copy(h.mtime,    "00000000000",                    11)
		ffi.copy(h.magic,    "ustar",                          5)
		ffi.copy(h.version,  "00",                             2)
		h.typeflag = string.byte("0")
		local sum = 8 * 32
		local hp  = ffi.cast("const uint8_t *", h)
		for i = 0, tarHeaderSize - 1 do sum = sum + hp[i] end
		ffi.copy(h.checksum, string.format("%06o\0 ", sum), 8)
		out:putcdata(h, tarHeaderSize)
		out:put(content)
		local pad = (512 - (#content % 512)) % 512
		if pad > 0 then out:put(string.rep("\0", pad)) end
	end
	out:put(string.rep("\0", 1024))
	local tarData = out:tostring()
	local final   = toPath:match("%.tar%.gz$") and deflate.gzipCompress(tarData) or tarData
	return fs.write(toPath, final)
end

-- ── Archive ───────────────────────────────────────────────────────────────────

---@class Archive
---@field _source string | table<string, string>
local Archive = {}
Archive.__index = Archive

---@class Archive.ExtractOptions
---@field stripComponents boolean?

--- Create a new Archive.
--- Pass a file path string to decode, or a table of `{ [path] = content }` to encode.
---@param source string | table<string, string>
---@return Archive
function Archive.new(source)
	return setmetatable({ _source = source }, Archive)
end

--- Extract the archive to the given output directory.
---@param toPath string
---@param opts   Archive.ExtractOptions?
---@return boolean ok
---@return string? err
function Archive:extract(toPath, opts)
	local src = self._source
	if type(src) ~= "string" then return false, "extract() is only valid for file-backed archives" end
	local f = io.open(src, "rb")
	if not f then return false, "cannot open: " .. src end
	local data = f:read("*a"); f:close()
	local strip = opts and opts.stripComponents or false
	fs.mkdir(toPath)
	local ok, err = pcall(function()
		if ffi.cast("const uint32_t *", data)[0] == 0x04034b50 then
			zipExtract(data, toPath, strip)
		else
			local raw = data:sub(1, 2) == "\31\139" and deflate.gzipDecompress(data, math.max(#data * 10, 1024 * 1024)) or data
			tarExtract(raw, toPath, strip)
		end
	end)
	if not ok then return false, err end
	return true
end

--- Save the in-memory file table to an archive.
--- Infers format from extension: `.zip`, `.tar`, or `.tar.gz`.
---@param toPath string
---@return boolean ok
---@return string? err
function Archive:save(toPath)
	local src = self._source
	if type(src) ~= "table" then return false, "save() is only valid for table-backed archives" end
	local isZip = toPath:match("%.zip$")
	local isTar = toPath:match("%.tar")
	if not isZip and not isTar then
		return false, "cannot determine archive format from path (expected .zip or .tar.gz)"
	end
	local ok, err = pcall(function()
		if isZip then zipSave(src, toPath) else tarSave(src, toPath) end
	end)
	if not ok then return false, err end
	return true
end

return Archive
