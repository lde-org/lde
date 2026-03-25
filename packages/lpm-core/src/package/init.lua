local Config = require("lpm-core.config")
local Lockfile = require("lpm-core.lockfile")
local rocked = require("rocked")
local sea = require("sea")

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
---@field buildfn (fun(pkg: lpm.Package, outputDir: string): boolean, string?)?
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

---@param pkg lpm.Package
---@param outputDir string
local function defaultBuildFn(pkg, outputDir)
	fs.copy(pkg:getSrcDir(), outputDir)

	local buildScriptPath = pkg:getBuildScriptPath()
	if not fs.exists(buildScriptPath) then
		return nil, "No build script found: " .. buildScriptPath
	end

	return pkg:runFile(buildScriptPath, nil, { LPM_OUTPUT_DIR = outputDir })
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
---@return lpm.Package?, string?
function Package.openLPM(dir)
	dir = dir or env.cwd()

	local configPath = configPathAtDir(dir)
	if not fs.exists(configPath) then
		return nil, "No lpm.json found in directory: " .. dir
	end

	return setmetatable({ dir = dir }, Package), nil
end

---@param dir string?
---@param rockspecPath string? # Path to the rockspec file; if nil, scanned from dir
---@return lpm.Package?, string?
function Package.openRockspec(dir, rockspecPath)
	dir = dir or env.cwd()

	if not rockspecPath then
		if fs.isdir(dir) then
			for _, entry in ipairs(fs.scan(dir, "**.rockspec")) do
				rockspecPath = path.join(dir, entry)
				break
			end
		end
	elseif not path.isAbsolute(rockspecPath) then
		rockspecPath = path.join(dir, rockspecPath)
	end

	if not rockspecPath then
		return nil, "No rockspec found in directory: " .. dir
	end

	local content = fs.read(rockspecPath)
	if not content then
		return nil, "Could not read rockspec: " .. rockspecPath
	end

	local ok, spec = rocked.parse(content)
	if not ok then
		return nil, "Failed to parse rockspec: " .. (spec or rockspecPath)
	end ---@cast spec rocked.raw.Output

	local pkg = setmetatable({ dir = dir }, Package)

	-- Collect pure-Lua module_name -> src_path from build.modules and build.install.lua
	local modules = {}
	local nativeModules = {} -- modname -> src_path (.c)
	if spec.build then
		for modname, src in pairs(spec.build.modules or {}) do
			if type(src) == "string" then
				if src:match("%.lua$") then
					modules[modname] = src
				elseif src:match("%.c$") then
					nativeModules[modname] = src
				end
			end
		end
		for modname, src in pairs((spec.build.install or {}).lua or {}) do
			modules[modname] = src
		end
	end

	local entryModule = spec.package and spec.package:lower()

	pkg.buildfn = function(_, outputDir)
		local modulesDir = path.dirname(outputDir)

		for modname, src in pairs(modules) do
			local srcAbs = path.join(dir, src)
			local destRel = modname:gsub("%.", path.separator) .. ".lua"
			-- Mangle if this would collide with the generated init.lua
			if path.join(modulesDir, destRel) == path.join(outputDir, "init.lua") then
				destRel = modname:gsub("%.", path.separator):gsub("init$", "__init") .. ".lua"
			end
			local destAbs = path.join(modulesDir, destRel)
			local destDir = path.dirname(destAbs)
			if not fs.isdir(destDir) then
				fs.mkdir(destDir)
			end
			fs.copy(srcAbs, destAbs)
			modules[modname] = { destRel = destRel, destAbs = destAbs }
		end

		for modname, src in pairs(nativeModules) do
			local srcAbs = path.join(dir, src)
			local ext = process.platform == "darwin" and "dylib" or "so"
			local destRel = modname:gsub("%.", path.separator) .. "." .. ext
			local destAbs = path.join(modulesDir, destRel)
			local destDir = path.dirname(destAbs)
			if not fs.isdir(destDir) then
				fs.mkdir(destDir)
			end

			local ok, err = process.exec("gcc", {
				"-shared", "-fPIC",
				"-I" .. path.join(sea.getLuajitPath(), "include"),
				srcAbs,
				"-o", destAbs,
			})
			if not ok then
				return nil, "Failed to compile native module '" .. modname .. "': " .. (err or "")
			end
		end

		local lines = {
			"local _dir = debug.getinfo(1,'S').source:sub(2):match('^(.*/)') or './'",
		}
		for modname, info in pairs(modules) do
			table.insert(lines, string.format(
				"package.preload[%q] = package.preload[%q] or function() return dofile(_dir .. %q) end",
				modname, modname, "../" .. info.destRel
			))
		end
		if entryModule then
			local info = modules[entryModule] or modules[entryModule .. ".init"]
			if info then
				table.insert(lines, string.format("return dofile(_dir .. %q)", "../" .. info.destRel))
			elseif nativeModules[entryModule] then
				local ext = process.platform == "darwin" and "dylib" or "so"
				table.insert(lines, string.format(
					"return package.loadlib(_dir .. %q, %q)()",
					"../" .. entryModule:gsub("%.", path.separator) .. "." .. ext,
					"luaopen_" .. entryModule:gsub("%.", "_")
				))
			end
		end

		fs.write(path.join(outputDir, "init.lua"), table.concat(lines, "\n") .. "\n")

		return true
	end

	pkg.readConfig = function()
		return Config.new({ name = spec.package, version = spec.version })
	end

	return pkg, nil
end

---@param dir string?
---@param rockspec string? # Path to rockspec, forwarded to openRockspec if no lpm.json
---@return lpm.Package?, string?
function Package.open(dir, rockspec)
	dir = dir or env.cwd()

	if fs.exists(configPathAtDir(dir)) then
		return Package.openLPM(dir)
	end

	return Package.openRockspec(dir, rockspec)
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
