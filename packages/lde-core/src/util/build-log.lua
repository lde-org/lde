-- Failure-log capture for build.lua scripts.
--
-- build.lua output is hidden by default (compact install mode): stdout from
-- build:sh / guest print calls is captured in memory instead of streamed, so
-- a 500-line cmake configure no longer floods the terminal. If the build
-- fails, the capture is written to a deterministic file under the temp dir
-- and the error message points at it:
--
--   error: Build failed for 'curl-sys'
--     full output at /tmp/lde-build-curl-sys-1a2b3c4d.log
--
-- The path is derived only from the output dir, so an async build worker
-- (a separate `lde __build-pkg` process) and its parent agree on the file
-- without passing it over the wire.

local fs = require("fs")
local path = require("path")
local util = require("util")

---@class lde.buildLog.Capture
---@field parts string[]
---@field append fun(self: lde.buildLog.Capture, ...: string?) # buffer strings (e.g. child stdout/stderr)
---@field write fun(self: lde.buildLog.Capture, destPath: string): string # persist to the temp log file, returns its path

---@type table<string, boolean> # sanitized package names already given a log dir
local ensuredDirs = {}

local M = {}

---@return string
local function tmpDir()
	if jit.os == "Windows" then
		return os.getenv("TEMP") or os.getenv("TMP") or "."
	end
	return os.getenv("TMPDIR") or "/tmp"
end

--- Deterministic failure-log path for a build output dir. Both the build
--- worker and the install scheduler can compute it, so the scheduler can
--- reference the file the worker wrote on failure.
---@param destPath string # the build output dir (target/<name>)
---@return string
function M.pathFor(destPath)
	local name = path.basename(destPath) or "pkg"
	local h = util.hash(destPath):sub(1, 8)
	return path.join(tmpDir(), "lde-build-" .. name .. "-" .. h .. ".log")
end

---@return lde.buildLog.Capture
function M.newCapture()
	local c = { parts = {} }
	function c:append(...)
		for i = 1, select("#", ...) do
			local s = select(i, ...)
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
