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
---@field buildfn (fun(pkg: lde.Package, outputDir: string): boolean?, string?, lde.install.DeferredBuild?)?
---@field buildNeedsDeps boolean? # false = pure-Lua builtin install that never reads dependency build outputs
---@field isRockspec boolean? # true when opened from a *.rockspec (no lde.json)
---@field rockspecData rocked.raw.Output? # parsed rockspec, when isRockspec
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

--- Resolve the directory a package should be opened from. Returns an error
--- when the caller falls back to the current working directory but it no
--- longer exists (e.g. the shell's cwd was deleted while it was open), since
--- env.cwd() returns nil there and downstream path joins would crash.
---@param dir string?
---@return string?, string? # resolved directory, or nil + error message
local function resolveDir(dir)
	if dir then return dir, nil end

	local cwd = env.cwd()
	if not cwd then
		return nil, "Current working directory no longer exists (it may have been deleted)"
	end

	return cwd, nil
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

	local source = fs.read(buildScriptPath)
	if not source then
		return nil, "Could not read build script: " .. buildScriptPath
	end

	local lua = require("lua-sys")
	local Instance = require("lde-build.build")

	local luaPath, luaCPath = require("lde-core.package.run").getLuaPaths(pkg)
	local state = lua.new()
	local g     = state:globals()
	g.package.path  = luaPath
	g.package.cpath = luaCPath

	-- Set LDE_OUTPUT_DIR so build scripts can read it via os.getenv
	env.set("LDE_OUTPUT_DIR", outputDir)
	env.set("LPM_OUTPUT_DIR", outputDir)

	-- Expose the C compiler and make binaries and, on Windows, prepend the
	-- toolchain bin dir to PATH so child processes spawned by build:sh()
	-- (cmake, ninja, make, sh, etc.) can find them.
	local ccBin = global.getCCBin()
	local makeBin = global.getMakeBin()
	local oldCC  = env.var("CC") or ""
	local oldMAKE = env.var("MAKE") or ""
	local oldPATH = env.var("PATH") or ""
	env.set("CC", ccBin)
	env.set("MAKE", makeBin)
	if jit.os == "Windows" then
		local mingwBinDir = path.dirname(ccBin)
		if not oldPATH:find(mingwBinDir, 1, true) then
			env.set("PATH", mingwBinDir .. ";" .. oldPATH)
		end
	end

	-- Inject lde-build instance into the guest state
	Instance.setup(state, outputDir, ccBin)

	local cwd = pkg:getDir()
	local oldCwd = env.cwd()
	env.chdir(cwd)

	local ok, err = pcall(state.eval, state, source)

	env.chdir(oldCwd)
	env.set("LDE_OUTPUT_DIR", "")
	env.set("LPM_OUTPUT_DIR", "")
	env.set("CC", oldCC)
	env.set("MAKE", oldMAKE)
	if jit.os == "Windows" then env.set("PATH", oldPATH) end
	state:close()

	return ok, err
end

function Package:hasBuildScript()
	return self.buildfn ~= nil or fs.exists(self:getBuildScriptPath())
end

---@param outputDir string
---@return boolean? ok
---@return string? err
---@return lde.install.DeferredBuild? deferred # non-nil when the build spawned async native compiles
function Package:runBuildScript(outputDir)
	return (self.buildfn or defaultBuildFn)(self, outputDir)
end

---@param dir string?
---@return lde.Package?, string?
function Package.openLDE(dir)
	local resolved, err = resolveDir(dir)
	if not resolved then return nil, err end
	dir = resolved

	local configPath = configPathAtDir(dir)
	if not fs.exists(configPath) then
		return nil, "No lde.json found in directory: " .. dir
	end

	return setmetatable({ dir = dir }, Package), nil
end

local rockspecModule = require("lde-core.package.rockspec")
Package.openRockspec = rockspecModule.open
-- Exposed for unit tests: pure native-module helpers (no toolchain needed).
Package.nativeGccArgs = rockspecModule.nativeGccArgs
Package.normalizeNativeModule = rockspecModule.normalizeNativeModule

---@param dir string?
---@param rockspec string? # Path to rockspec, forwarded to openRockspec if no lde.json
---@return lde.Package?, string?
function Package.open(dir, rockspec)
	local resolved, err = resolveDir(dir)
	if not resolved then return nil, err end
	dir = resolved

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
	local deps = self:readConfig().devDependencies or {}

	local lockfile = self:readLockfile()
	if not lockfile then return deps end

	-- Prefer locked versions (which have pinned commits) over lde.json, but
	-- preserve config-only flags (optional, features) that aren't stored in the
	-- lockfile — mirroring getDependencies().
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

function Package:getName()
	return self:readConfig().name
end

Package.build = require("lde-core.package.build").build

---@param dir string
---@param info lde.Package.Config.Dependency
---@param relativeTo string?
function Package:getDependencyPath(dir, info, relativeTo)
	relativeTo = relativeTo or self.dir

	if info.git then
		if not info.commit then return nil, "no commit pinned for '" .. dir .. "'" end
		return global.getGitRepoDir(dir, info.commit)
	elseif info.path then
		return path.normalize(path.join(relativeTo, info.path))
	elseif info.archive then
		return global.getOrInitArchive(info.archive)
	end
end

Package.installDependencies = require("lde-core.package.install")

---@param opts { summary: boolean?, locked: boolean? }?
function Package:installDevDependencies(opts)
	return self:installDependencies(self:getDevDependencies(), nil, nil, opts)
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
Package.createState = run.createState
Package.runTests = require("lde-core.package.test")

--- Quote a single argument for the shell that will run the script so it is
--- received verbatim: POSIX sh single quotes, cmd.exe double quotes.
---@param arg string
---@param isCmd boolean? # cmd.exe escaping instead of POSIX
---@return string
local function shellQuote(arg, isCmd)
	if isCmd then
		return '"' .. arg:gsub('"', '""') .. '"'
	end
	return "'" .. arg:gsub("'", "'\\''") .. "'"
end

---@param name string # Name of a script defined in lde.json scripts table
---@param capture boolean? # If true, capture stdout/stderr instead of inheriting them
---@param args string[]? # Extra args appended to the script command (e.g. from `-- <args>`)
---@return boolean?
---@return string?
function Package:runScript(name, capture, args)
	local scripts = self:readConfig().scripts
	if not scripts or not scripts[name] then
		error("No script named '" .. name .. "' in lde.json")
	end
	local opts = { cwd = self:getDir() }
	if not capture then
		opts.stdout = "inherit"
		opts.stderr = "inherit"
	end

	local shellBin, shellFlag, isCmd = global.getScriptShell()

	local cmd = scripts[name]
	if args and #args > 0 then
		local quoted = {}
		for i = 1, #args do
			quoted[i] = shellQuote(args[i], isCmd)
		end
		cmd = cmd .. " " .. table.concat(quoted, " ")
	end

	local code, stdout, stderr = process.exec(shellBin, { shellFlag, cmd }, opts)
	if code == 0 then return true, stdout or stderr end
	-- process.exec returns empty strings (not nil) when the child wrote nothing;
	-- treat those as absent so a silent failure reports its exit code.
	if stdout and stdout ~= "" then return nil, stdout end
	if stderr and stderr ~= "" then return nil, stderr end
	return nil, "Script exited with " .. (code and ("exit code " .. tostring(code)) or "an unknown error")
end

return Package
