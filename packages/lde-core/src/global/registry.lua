--- The lde registry client, built on first use.

local fs = require("fs")
local path = require("path")
local semver = require("semver")
const util = require("util")

const lde = require("lde-core")
const dirs = require("lde-core.global.dirs")
const config = require("lde-core.global.config")
const git2 = util.lazy(|| -> require("git2-sys"))

local registered

local M = {}

-- The registry client is built on first use, not at module load: wiring it
-- up requires lde-registry, lde-core.util (which pulls in rocked/luarocks)
-- and the config file read, all of which a command that never touches the
-- registry (run, -e, install of already-pinned deps, …) would pay for on
-- every startup. Tests construct their own lde.Registry instances with
-- injected fakes instead.
---@return lde.Registry
local function getRegistry()
	if not registered then
		registered = require("lde-registry").new({
			dirFn = function() return path.join(dirs.getDir(), "registry") end,
			url = config().registry,
			fs = fs --[[@as lde.RegistryFs]],
			path = path --[[@as lde.RegistryPath]],
			semver = semver --[[@as lde.RegistrySemver]],
			git = git2,
			decodeJson = require("lde-core.util").decodeJson,
			raise = lde.error.raise,
		})
	end
	return registered
end

function M.getRegistryDir()
	return getRegistry():getDir()
end

function M.syncRegistry()
	getRegistry():sync()
end

---@param name string
---@return lde.Portfile?
---@return string? sha
---@return string? err
function M.lookupRegistryPackage(name)
	return getRegistry():lookup(name)
end

---@param portfile lde.Portfile
---@param version string?
---@return string version
---@return string repoDir
---@return string commit
function M.resolveRegistryVersion(portfile, version)
	return getRegistry():resolveVersion(portfile, version)
end

---@param name string
---@return string? err
function M.validatePackageName(name)
	return getRegistry():validateName(name)
end

return M
