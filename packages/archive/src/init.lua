local process = require("process2")
local fs = require("fs")
local path = require("path")

local ZIP_MAGIC = "\80\75\3\4" -- PK\x03\x04

---@param filePath string
---@return boolean
local function isZip(filePath)
	local f = io.open(filePath, "rb")
	if not f then return false end
	local magic = f:read(4)
	f:close()
	return magic == ZIP_MAGIC
end

---@class Archive
---@field _source string | table<string, string>
local Archive = {}
Archive.__index = Archive

--- Create a new Archive.
--- Pass a file path string to decode, or a table of `{ [path] = content }` to encode.
---@param source string | table<string, string>
---@return Archive
function Archive.new(source)
	return setmetatable({ _source = source }, Archive)
end

---@class Archive.ExtractOptions
---@field stripComponents boolean? # Strip the single top-level directory when extracting (default: false)

--- Extract the archive to the given output directory.
--- Only valid when the Archive was created with a file path.
---@param toPath string
---@param opts Archive.ExtractOptions?
---@return boolean ok
---@return string? err
function Archive:extract(toPath, opts)
	local src = self._source
	if type(src) ~= "string" then
		return false, "extract() is only valid for file-backed archives"
	end

	local strip = opts and opts.stripComponents or false
	local code, _, stderr

	if jit.os == "Linux" and isZip(src) then
		if strip then
			local tmpDir = toPath .. ".tmp"
			code, _, stderr = process.exec("unzip", { "-q", src, "-d", tmpDir })
			if code == 0 then
				local iter = fs.readdir(tmpDir)
				local first = iter and iter()
				local inner = (first and first.type == "dir") and path.join(tmpDir, first.name) or tmpDir
				fs.move(inner, toPath)
				fs.rmdir(tmpDir)
			end
		else
			code, _, stderr = process.exec("unzip", { "-q", src, "-d", toPath })
		end
	else
		local args = { "-xf", src, "-C", toPath }
		if strip then args[#args + 1] = "--strip-components=1" end
		code, _, stderr = process.exec("tar", args)
	end

	if code ~= 0 then
		return false, stderr
	end

	return true
end

--- Save the in-memory file table to an archive.
--- Infers format from extension: `.zip` or `.tar.gz`.
--- Only valid when the Archive was created with a table.
---@param toPath string
---@return boolean ok
---@return string? err
function Archive:save(toPath)
	local src = self._source
	if type(src) ~= "table" then
		return false, "save() is only valid for table-backed archives"
	end

	local isZipOut = toPath:match("%.zip$") ~= nil
	local isTarGz  = toPath:match("%.tar%.gz$") ~= nil
	if not isZipOut and not isTarGz then
		return false, "cannot determine archive format from path (expected .zip or .tar.gz)"
	end

	local tmpDir = toPath .. ".tmp"
	fs.mkdir(tmpDir)

	for name, content in pairs(src) do
		local filePath = path.join(tmpDir, name)
		local dir = path.dirname(filePath)
		if dir then fs.mkdir(dir) end
		if not fs.write(filePath, content) then
			fs.rmdir(tmpDir)
			return false, "failed to write temp file: " .. filePath
		end
	end

	local code, _, stderr
	if isZipOut and jit.os ~= "Windows" then
		code, _, stderr = process.exec("zip", { "-qr", toPath, "." }, { cwd = tmpDir })
	elseif isZipOut then
		code, _, stderr = process.exec("tar", { "-cf", toPath, "-C", tmpDir, "." })
	else
		code, _, stderr = process.exec("tar", { "-czf", toPath, "-C", tmpDir, "." })
	end

	fs.rmdir(tmpDir)

	if code ~= 0 then
		return false, stderr
	end

	return true
end

return Archive
