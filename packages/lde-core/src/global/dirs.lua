--- Global lde directory layout and user-level paths.

local path = require("path")

local M = {}

function M.sanitize(s)
	if not s then return "" end
	return (string.gsub(s, "[^%w_%-]", "_"))
end

---@type string?
local dirOverride = nil

---@param dir string?
function M.setDir(dir)
	dirOverride = dir
end

--- The lde dir in use: the --tree override when one was passed, otherwise the
--- user dir (see getUserDir). Defaulting to getUserDir keeps every cache and
--- tool under one home while --tree still redirects the whole tree elsewhere.
function M.getDir()
	if dirOverride then return dirOverride end
	return M.getUserDir()
end

--- The user-level lde directory, independent of any --tree override. Set via
--- the LDE_HOME env var when present (its value is the lde dir itself),
--- otherwise ~/.lde. Global registry metadata (the luarocks manifest, the
--- resolved-URL cache) lives here so per-tree installs share it instead of
--- re-downloading per tree.
function M.getUserDir()
	const ldeHome = os.getenv("LDE_HOME")
	if ldeHome and ldeHome ~= "" then return ldeHome end
	return path.join(os.getenv("HOME") or os.getenv("USERPROFILE") or "", ".lde")
end

function M.getConfigPath()
	return path.join(M.getDir(), "config.json")
end

function M.getGitCacheDir()
	return path.join(M.getDir(), "git")
end

function M.getTarCacheDir()
	return path.join(M.getDir(), "tar")
end

function M.getRockspecCacheDir()
	return path.join(M.getDir(), "rockspecs")
end

function M.getToolsDir()
	return path.join(M.getDir(), "tools")
end

function M.getMingwDir()
	return path.join(M.getDir(), "mingw")
end

return M
