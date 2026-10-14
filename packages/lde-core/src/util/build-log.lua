-- Build output is captured in memory and written to a deterministic temp log on failure; the path derives only from the output dir, so an async worker and its parent agree on it.

const fs = require("fs")
const path = require("path")
const util = require("util")

---@class lde.buildLog.Capture
---@field parts string[]
---@field append fun(self: lde.buildLog.Capture, ...: string?) # buffer strings (e.g. child stdout/stderr)
---@field write fun(self: lde.buildLog.Capture, destPath: string): string # persist to the temp log file, returns its path

---@type table<string, boolean> # sanitized package names already given a log dir
const ensuredDirs = {}

const M = {}

local function tmpDir()
	if jit.os == "Windows" then
		return os.getenv("TEMP") or os.getenv("TMP") or "."
	end
	return os.getenv("TMPDIR") or "/tmp"
end

--- Both the build worker and the install scheduler can compute this, so the scheduler can reference the worker's log on failure.
---@param destPath string # the build output dir (target/<name>)
function M.pathFor(destPath)
	const name = path.basename(destPath) or "pkg"
	const h = util.hash(destPath):sub(1, 8)
	return path.join(tmpDir(), "lde-build-" .. name .. "-" .. h .. ".log")
end

---@return lde.buildLog.Capture
function M.newCapture()
	const c = { parts = {} }
	function c:append(...)
		for i = 1, select("#", ...) do
			const s = select(i, ...)
			if type(s) == "string" and s ~= "" then
				self.parts[#self.parts + 1] = s
			end
		end
	end
	function c:write(destPath)
		local p = M.pathFor(destPath)
		local dir = path.dirname(p)
		if not ensuredDirs[dir] then
			fs.mkdirAll(dir)
			ensuredDirs[dir] = true
		end
		fs.write(p, table.concat(self.parts))
		return p
	end
	return c
end

return M
