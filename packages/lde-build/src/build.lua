local curl = require("curl-sys")
local fs = require("fs")
local path = require("path")
local archive = require("archive")

---@class lde.build.Instance
---@field outDir string
local Instance = {}
Instance.__index = Instance

---@param outDir string
---@return lde.build.Instance
function Instance.new(outDir)
	return setmetatable({ outDir = outDir }, Instance)
end

---@return string
function Instance:fetch(url)
	local res, err = curl.get(url)
	if not res then
		error("failed to fetch " .. url .. ": " .. err)
	end

	return res.body
end

---@param rel string # Relative path at output dir
---@param content string
function Instance:write(rel, content)
	local full = path.join(self.outDir, rel)
	fs.mkdirAll(path.dirname(full))
	assert(fs.write(full, content), "failed to write " .. full)
end

---@param rel string # Relative path at output dir
---@return string
function Instance:read(rel)
	local full = path.join(self.outDir, rel)
	local res = fs.read(full)
	assert(res, "failed to read " .. full)
	return res
end

---@param rel string # Relative path at output dir
---@param dest string # Relative path at output dir
function Instance:extract(rel, dest)
	local full = path.join(self.outDir, rel)

	local ok, err = archive.new(full):extract(path.join(self.outDir, dest))
	if not ok then
		error("failed to extract " .. full .. ": " .. err)
	end
end

---@param rel string # Relative path at output dir
---@param dest string # Relative path at output dir
function Instance:copy(rel, dest)
	local full = path.join(self.outDir, rel)

	local ok, err = fs.copy(full, path.join(self.outDir, dest))
	if not ok then
		error("failed to copy " .. full .. ": " .. err)
	end
end

---@param rel string # Relative path at output dir
function Instance:delete(rel)
	local full = path.join(self.outDir, rel)

	local ok, err = fs.delete(full)
	if not ok then
		error("failed to remove " .. full .. ": " .. err)
	end
end

---@param rel string # Relative path at output dir
---@param dest string # Relative path at output dir
function Instance:move(rel, dest)
	local full = path.join(self.outDir, rel)

	local ok, err = fs.move(full, path.join(self.outDir, dest))
	if not ok then
		error("failed to move " .. full .. ": " .. err)
	end
end

---@param rel string # Relative path at output dir
function Instance:exists(rel)
	local full = path.join(self.outDir, rel)
	return fs.exists(full)
end

---@param cmd string
function Instance:sh(cmd)
	local res = os.execute(cmd)
	assert(res == 0, "failed to execute " .. cmd)
end

return Instance
