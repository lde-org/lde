local path = require("path")

---@class fs.Stat
---@field size number # Size in bytes
---@field accessTime number
---@field modifyTime number
---@field type fs.Stat.Type?
---@field mode number? # Permission bits (Unix only)

---@alias fs.Stat.Type fs.DirEntry.Type
---@alias fs.DirEntry.Type "file" | "dir" | "symlink" | "unknown"

---@class fs.DirEntry
---@field name string
---@field type fs.DirEntry.Type

---@alias fs.WatchEvent "create" | "modify" | "delete" | "rename"

---@class fs.Watcher
---@field poll fun()
---@field wait fun()
---@field close fun()

---@class fs.raw
---@field exists fun(p: string): boolean
---@field isdir fun(p: string): boolean
---@field islink fun(p: string): boolean
---@field isfile fun(p: string): boolean
---@field readdir fun(p: string): (fun(): fs.DirEntry?)?
---@field mkdir fun(p: string): boolean
---@field mklink fun(src: string, dest: string): boolean
---@field rmlink fun(p: string): boolean
---@field stat fun(p: string): fs.Stat?
---@field lstat fun(p: string): fs.Stat?
---@field watch fun(p: string, callback: fun(event: fs.WatchEvent, name: string), opts: { recursive: boolean? }?): fs.Watcher?

local rawfs ---@type fs.raw
if jit.os == "Windows" then
	rawfs = require("fs.raw.windows")
elseif jit.os == "Linux" then
	rawfs = require("fs.raw.linux")
elseif jit.os == "OSX" then
	rawfs = require("fs.raw.macos")
else
	error("Unsupported OS: " .. jit.os)
end

---@class fs: fs.raw
local fs = {}

for k, v in pairs(rawfs) do
	fs[k] = v
end

---@param p string
---@return string|nil
function fs.read(p)
	local file = io.open(p, "rb")
	if not file then
		return nil
	end

	local content = file:read("*a")
	file:close()

	return content
end

---@param p string
---@param content string
---@return boolean
function fs.write(p, content)
	local file = io.open(p, "wb")
	if not file then
		return false
	end

	file:write(content)
	file:close()

	return true
end

---@param src string
---@param dest string
function fs.copy(src, dest)
	if fs.isfile(src) then
		local content = fs.read(src)
		if not content then return false end
		fs.write(dest, content)
		return true
	end

	local iter = fs.readdir(src)
	if not iter then return false end
	if not fs.isdir(dest) and not fs.mkdir(dest) then return false end

	for entry in iter do
		local srcPath = path.join(src, entry.name)
		local destPath = path.join(dest, entry.name)

		local r = fs.copy(srcPath, destPath)
		if not r then
			return false
		end
	end

	return true
end

---@param old string
---@param new string
function fs.move(old, new)
	-- Fast path: os.rename works for both files and dirs on same device
	if os.rename(old, new) then
		return true
	end

	-- Fallback to copy+delete for cross-device moves
	if not fs.copy(old, new) then return false, "Failed to copy" end
	local ok = fs.isdir(old) and fs.rmdir(old) or fs.delete(old)
	if not ok then return false, "Failed to delete" end

	return true
end

---@param p string
function fs.delete(p)
	return os.remove(p) ~= nil
end

--- Recursively removes a directory and all its contents.
---@param dir string
---@return boolean
function fs.rmdir(dir)
	if not fs.exists(dir) then return false end

	-- Symlinks/junctions: remove the link itself without recursing into the target.
	-- On Windows, junctions require RemoveDirectoryA (not DeleteFileA/os.remove).
	if fs.islink(dir) then
		return fs.rmlink(dir)
	end

	local iter = fs.readdir(dir)
	if not iter then return false end

	for entry in iter do
		local full = path.join(dir, entry.name)
		if entry.type == "symlink" then
			fs.rmlink(full)
		elseif entry.type == "dir" then
			fs.rmdir(full)
		else
			os.remove(full)
		end
	end

	return fs.rmlink(dir)
end

local sep = string.sub(package.config, 1, 1)

---@param glob string
function fs.globToPattern(glob)
	local pattern = glob
		:gsub("([%^%$%(%)%%%.%[%]%+%-])", "%%%1")
		:gsub("%*%*", "\001")
		:gsub("%*", "[^/\\]*")
		:gsub("%?", "[^/\\]")
		:gsub("\001", ".*")

	return "^" .. pattern .. "$"
end

---@param cwd string
---@param glob string
---@param opts { absolute: boolean, followSymlinks: boolean }?
---@return string[]
function fs.scan(cwd, glob, opts)
	if not fs.isdir(cwd) then
		error("not a directory: '" .. cwd .. "'")
	end

	local absolute = opts and opts.absolute or false
	local followSymlinks = opts and opts.followSymlinks or false

	local pattern = fs.globToPattern(glob)
	local entries = {}

	local function dir(p)
		local dirIter = fs.readdir(p)
		if not dirIter then
			return
		end

		for entry in dirIter do
			local entryPath = p .. sep .. entry.name
			local entryType = entry.type

			-- d_type can be DT_UNKNOWN on some filesystems; fall back to lstat
			if entryType == "unknown" then
				local s = fs.lstat(entryPath)
				entryType = s and s.type or "unknown"
			end

			-- Resolve symlinks when followSymlinks is set
			if entryType == "symlink" and followSymlinks then
				local s = fs.stat(entryPath)
				entryType = s and s.type or "unknown"
			end

			if entryType == "dir" then
				dir(entryPath)
			elseif entryType == "file" then
				if string.find(entryPath, pattern) then
					if absolute then
						entries[#entries + 1] = entryPath
					else
						entries[#entries + 1] = path.relative(cwd, entryPath)
					end
				end
			end
		end
	end

	dir(cwd)
	return entries
end

return fs
