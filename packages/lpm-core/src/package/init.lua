local Config = require("lpm-core.config")
local Lockfile = require("lpm-core.lockfile")

local global = require("lpm-core.global")

local fs = require("fs")
local env = require("env")
local json = require("json")
local path = require("path")
local process = require("process")

---@class lpm.Package
---@field dir string
---@field cachedConfig lpm.Config?
---@field cachedConfigMtime number?
local Package = {}
Package.__index = Package

-- Add this since files in . will want access to the `Package` class.
package.loaded[(...)] = Package

---@param dir string
local function configPathAtDir(dir)
	return path.join(dir, "lpm.json")
end

function Package:getDir() return self.dir end

function Package:getBuildScriptPath() return path.join(self.dir, "build.lua") end

function Package:getLuarcPath() return path.join(self.dir, ".luarc.json") end

function Package:getModulesDir() return path.join(self.dir, "target") end

function Package:getTargetDir() return path.join(self:getModulesDir(), self:getName()) end

function Package:getSrcDir() return path.join(self.dir, "src") end

function Package:getTestDir() return path.join(self.dir, "tests") end

function Package:getConfigPath() return configPathAtDir(self.dir) end

function Package:getLockfilePath() return path.join(self.dir, "lpm-lock.json") end

---@param dir string?
---@return lpm.Package?, string?
function Package.open(dir)
	dir = dir or env.cwd()

	local configPath = configPathAtDir(dir)
	if not fs.exists(configPath) then
		return nil, "No lpm.json found in directory: " .. dir
	end

	return setmetatable({ dir = dir }, Package), nil
end

---@return lpm.Config
function Package:readConfig()
	local configPath = self:getConfigPath()

	local s = fs.stat(configPath)
	if not s then
		error("Could not read lpm.json: " .. configPath)
	end

	if self.cachedConfig and self.cachedConfigMtime == s.modifyTime then
		return self.cachedConfig
	end

	local content = fs.read(configPath)
	if not content then
		error("Could not read lpm.json: " .. configPath)
	end

	local newConfig = Config.new(json.decode(content))
	self.cachedConfig = newConfig
	self.cachedConfigMtime = s.modifyTime

	return newConfig
end

---@return lpm.Lockfile?
function Package:readLockfile()
	return Lockfile.open(self:getLockfilePath())
end

Package.init = require("lpm-core.package.initialize")

function Package:__tostring()
	return "Package(" .. self.dir .. ")"
end

function Package:getDependencies()
	local deps = self:readConfig().dependencies or {}

	local lockfile = self:readLockfile()
	if not lockfile then return deps end

	-- Prefer locked versions (which have pinned commits) over lpm.json
	local merged = {}
	for name, depInfo in pairs(deps) do
		merged[name] = lockfile:getDependency(name) or depInfo
	end
	return merged
end

function Package:getDevDependencies()
	return self:readConfig().devDependencies or {}
end

function Package:getName()
	return self:readConfig().name
end

Package.build = require("lpm-core.package.build")

---@param dir string
---@param info lpm.Config.Dependency
---@param relativeTo string?
function Package:getDependencyPath(dir, info, relativeTo)
	relativeTo = relativeTo or self.dir

	if info.git then
		return global.getGitRepoDir(dir, info.branch, info.commit)
	elseif info.path then
		return path.normalize(path.join(relativeTo, info.path))
	end
end

Package.installDependencies = require("lpm-core.package.install")

function Package:installDevDependencies()
	self:installDependencies(self:getDevDependencies())
end

Package.updateDependencies = require("lpm-core.package.update")

function Package:updateDevDependencies()
	return self:updateDependencies(self:getDevDependencies())
end

Package.compile = require("lpm-core.package.compile")
Package.runFile = require("lpm-core.package.run")
Package.runTests = require("lpm-core.package.test")

---@param name string # Name of a script defined in lpm.json scripts table
---@param capture boolean? # If true, capture stdout/stderr instead of inheriting them
---@return boolean?
---@return string?
function Package:runScript(name, capture)
	local scripts = self:readConfig().scripts
	if not scripts or not scripts[name] then
		error("No script named '" .. name .. "' in lpm.json")
	end
	local opts = { unsafe = true, cwd = self:getDir() }
	if not capture then
		opts.stdout = "inherit"
		opts.stderr = "inherit"
	end
	return process.exec(scripts[name], nil, opts)
end

return Package
