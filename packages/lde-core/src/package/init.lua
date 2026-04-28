local Lockfile = require("lde-core.lockfile")

local global = require("lde-core.global")

local fs = require("fs")
local env = require("env")
local json = require("json")
local path = require("path")
local process = require("process")

---@class lde.Package
---@field dir string
---@field cachedConfig lde.Package.Config?
---@field cachedConfigMtime number?
---@field buildfn (fun(pkg: lde.Package, outputDir: string): boolean, string?)?
local Package = {}
Package.__index = Package

-- Add this since files in . will want access to the `Package` class.
package.loaded[(...)] = Package

Package.Config = require("lde-core.package.config")

---@param dir string
local function configPathAtDir(dir)
	local legacyPath = path.join(dir, "lpm.json")
	if fs.exists(legacyPath) then
		return legacyPath
	end

	return path.join(dir, "lde.json")
end

function Package:getDir() return self.dir end

function Package:getBuildScriptPath() return path.join(self.dir, "build.lua") end

function Package:getLuarcPath() return path.join(self.dir, ".luarc.json") end

function Package:getModulesDir() return path.join(self.dir, "target") end

function Package:getTargetDir() return path.join(self:getModulesDir(), self:getName()) end

function Package:getSrcDir() return path.join(self.dir, "src") end

function Package:getTestDir() return path.join(self.dir, "tests") end

function Package:getConfigPath() return configPathAtDir(self.dir) end

function Package:getLockfilePath() return path.join(self.dir, "lde.lock") end

---@param pkg lde.Package
---@param outputDir string
local function defaultBuildFn(pkg, outputDir)
	fs.copy(pkg:getSrcDir(), outputDir)

	local buildScriptPath = pkg:getBuildScriptPath()
	if not fs.exists(buildScriptPath) then
		return nil, "No build script found: " .. buildScriptPath
	end

	local buildMod = require("lde-build.build")
	local buildInstance = buildMod.new(outputDir)

	return pkg:runFile(buildScriptPath, nil, {
		LDE_OUTPUT_DIR = outputDir,
		LPM_OUTPUT_DIR = outputDir -- compat
	}, nil, nil, nil, {
		["lde-build"] = function() return buildInstance end
	})
end

function Package:hasBuildScript()
	return self.buildfn ~= nil or fs.exists(self:getBuildScriptPath())
end

---@param outputDir string
---@return boolean? ok
---@return string? err
function Package:runBuildScript(outputDir)
	return (self.buildfn or defaultBuildFn)(self, outputDir)
end

---@param dir string?
---@return lde.Package?, string?
function Package.openLDE(dir)
	dir = dir or env.cwd()

	local configPath = configPathAtDir(dir)
	if not fs.exists(configPath) then
		return nil, "No lde.json found in directory: " .. dir
	end

	return setmetatable({ dir = dir }, Package), nil
end

Package.openRockspec = require("lde-core.package.rockspec")

---@param dir string?
---@param rockspec string? # Path to rockspec, forwarded to openRockspec if no lde.json
---@return lde.Package?, string?
function Package.open(dir, rockspec)
	dir = dir or env.cwd()

	if fs.exists(configPathAtDir(dir)) then
		return Package.openLDE(dir)
	end

	local pkg, _ = Package.openRockspec(dir, rockspec)
	if not pkg then
		return nil, "No package found in directory: " .. dir
	end

	return pkg
end

---@return lde.Package.Config
function Package:readConfig()
	local configPath = self:getConfigPath()

	local s = fs.stat(configPath)
	if not s then
		error("Could not read lde.json: " .. configPath)
	end

	if self.cachedConfig and self.cachedConfigMtime == s.modifyTime then
		return self.cachedConfig
	end

	local content = fs.read(configPath)
	if not content then
		error("Could not read lde.json: " .. configPath)
	end

	local newConfig = Package.Config.new(json.decode(content))
	self.cachedConfig = newConfig
	self.cachedConfigMtime = s.modifyTime

	return newConfig
end

---@return lde.Lockfile?
function Package:readLockfile()
	return Lockfile.open(self:getLockfilePath())
end

Package.init = require("lde-core.package.initialize")

function Package:__tostring()
	return "Package(" .. self.dir .. ")"
end

function Package:getDependencies()
	local deps = self:readConfig().dependencies or {}

	local lockfile = self:readLockfile()
	if not lockfile then return deps end

	-- Prefer locked versions (which have pinned commits) over lde.json,
	-- but preserve config-only flags (optional, features) that aren't stored in the lockfile
	local merged = {}
	for name, depInfo in pairs(deps) do
		local locked = lockfile:getDependency(name)
		if locked then
			locked.optional = depInfo.optional
			locked.features = depInfo.features
			merged[name] = locked
		else
			merged[name] = depInfo
		end
	end
	return merged
end

function Package:getDevDependencies()
	return self:readConfig().devDependencies or {}
end

function Package:getName()
	return self:readConfig().name
end

Package.build = require("lde-core.package.build")

---@param dir string
---@param info lde.Package.Config.Dependency
---@param relativeTo string?
function Package:getDependencyPath(dir, info, relativeTo)
	relativeTo = relativeTo or self.dir

	if info.git then
		return global.getGitRepoDir(dir, info.branch, info.commit)
	elseif info.path then
		return path.normalize(path.join(relativeTo, info.path))
	elseif info.archive then
		return global.getOrInitArchive(info.archive)
	end
end

Package.installDependencies = require("lde-core.package.install")

function Package:installDevDependencies()
	self:installDependencies(self:getDevDependencies())
end

Package.updateDependencies = require("lde-core.package.update")

function Package:updateDevDependencies()
	return self:updateDependencies(self:getDevDependencies())
end

Package.bundle = require("lde-core.package.bundle")
Package.compile = require("lde-core.package.compile")
local run = require("lde-core.package.run")
Package.runFile = run.runFile
Package.runString = run.runString
Package.runTests = require("lde-core.package.test")

---@param name string # Name of a script defined in lde.json scripts table
---@param capture boolean? # If true, capture stdout/stderr instead of inheriting them
---@return boolean?
---@return string?
function Package:runScript(name, capture)
	local scripts = self:readConfig().scripts
	if not scripts or not scripts[name] then
		error("No script named '" .. name .. "' in lde.json")
	end
	local opts = { cwd = self:getDir() }
	if not capture then
		opts.stdout = "inherit"
		opts.stderr = "inherit"
	end

	local shell = jit.os == "Windows" and { "cmd", "/c" } or { "sh", "-c" }
	local code, stdout, stderr = process.exec(shell[1], { shell[2], scripts[name] }, opts)
	return code == 0 or nil, stdout or stderr
end

return Package
