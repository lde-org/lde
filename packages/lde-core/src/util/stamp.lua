-- Change stamp for a set of input files: entries carry size/mtime and a content hash, so unchanged files are reused and only changed ones are re-hashed.

const fs = require("fs")
const json = require("json")
const util = require("util")

---@class lde.StampFile
---@field size number
---@field mtime number
---@field hash string

const M = {}

---@param stampPath string
---@param version number
---@return table<string, lde.StampFile> files
---@return string target # target key the stamp was built for ("" when absent)
function M.read(stampPath, version)
	local content = fs.read(stampPath)
	if not content then return {}, "" end
	local ok, decoded = pcall(json.decode, content)
	if not ok or type(decoded) ~= "table" or decoded.version ~= version or type(decoded.files) ~= "table" then
		return {}, ""
	end
	return decoded.files, type(decoded.target) == "string" ? decoded.target : ""
end

---@param entries table<string, string> # relative key -> absolute path
---@param stored table<string, lde.StampFile>
---@return boolean hasChanged
---@return table<string, lde.StampFile> current
function M.check(entries, stored)
	local current = {}
	local hasChanged = false

	for relPath, absPath in pairs(entries) do
		const stat = fs.stat(absPath)
		if not stat then
			hasChanged = true
			goto continue
		end

		-- fs.stat returns ffi cdata for these fields; coerce to plain numbers.
		local size, mtime = tonumber(stat.size), tonumber(stat.modifyTime)
		const prev = stored[relPath]
		if prev and prev.size == size and prev.mtime == mtime then
			current[relPath] = prev
		else
			local content = fs.read(absPath)
			if not content then
				hasChanged = true
				goto continue
			end
			local hash = util.hash(content)
			hasChanged = hasChanged or not prev or prev.hash ~= hash
			current[relPath] = { size = size, mtime = mtime, hash = hash }
		end

		::continue::
	end

	for relPath in pairs(stored) do
		if not current[relPath] then
			hasChanged = true
		end
	end

	return hasChanged, current
end

return M
