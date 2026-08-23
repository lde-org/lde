local Lockfile = require("lde-core.lockfile")

local lde = require("lde-core")

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
---@field hasBuildDeps boolean? # false = pure-Lua builtin install that never reads dependency build outputs
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
	-- fs.copy silently fails (and creates nothing) when src/ is missing, which
	-- would leave build:sh's cwd pointing at a nonexistent output dir. Ensure
	-- the output dir exists regardless so relative build-script paths always
	-- resolve against it.
	if fs.isdir(pkg:getSrcDir()) then
		fs.copy(pkg:getSrcDir(), outputDir)
	else
		fs.mkdirAll(outputDir)
	end

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
	local g     = state:globals() --[[@as { package: { path: string?, cpath: string? } }]]
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

	-- Parse and validate up front so a corrupt or nameless manifest fails
	-- cleanly at open instead of crashing later (getName, readConfig, ...).
	local stat = fs.stat(configPath)
	local content = fs.read(configPath)
	if not stat or not content then
		return nil, "Could not read lde.json: " .. configPath
	end

	local decoded, derr = lde.util.decodeJson(content)
	if not decoded then
		return nil, "Failed to parse " .. configPath .. ": " .. derr
	end
	if type(decoded.name) ~= "string" or decoded.name == "" then
		return nil, "Missing or invalid 'name' in " .. configPath
	end

	-- Dependency entries must be tables (or path shorthand strings); booleans
	-- and numbers crash downstream consumers (update, install) when indexed.
	for _, deps in ipairs({ decoded.dependencies, decoded.devDependencies }) do
		if deps ~= nil then
			if type(deps) ~= "table" then
				return nil, "Invalid 'dependencies' in " .. configPath
			end
			for alias, info in pairs(deps) do
				if type(info) ~= "table" and type(info) ~= "string" then
					return nil, "Invalid dependency '" .. tostring(alias) .. "' in " .. configPath
				end
			end
		end
	end

	return setmetatable({
		dir = dir,
		cachedConfig = Package.Config.new(decoded),
		cachedConfigMtime = stat.modifyTime,
	}, Package), nil
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

	local pkg, perr = Package.openRockspec(dir, rockspec)
	if not pkg then
		-- A rockspec that exists but fails to open (bad syntax, unreadable)
		-- should report the real error instead of the generic "no package"
		-- message, which makes a typo'd rockspec look like a missing one.
		local hasRockspec = rockspec ~= nil
		if not hasRockspec and fs.isdir(dir) then
			local iter = fs.readdir(dir)
			if iter then
				for entry in iter do
					if entry.type == "file" and entry.name:match("%.rockspec$") then
						hasRockspec = true
						break
					end
				end
			end
		end
		if hasRockspec then
			return nil, perr
		end
		return nil, "No package found in directory: " .. dir
	end

	return pkg
end

---@return lde.Package.Config
function Package:readConfig()
	local configPath = self:getConfigPath()

	local s = fs.stat(configPath)
	if not s then
		lde.error.raise("Could not read lde.json: " .. configPath)
	end ---@cast s -nil

	if self.cachedConfig and self.cachedConfigMtime == s.modifyTime then
		return self.cachedConfig
	end

	local content = fs.read(configPath)
	if not content then
		lde.error.raise("Could not read lde.json: " .. configPath)
	end ---@cast content -nil

	local decoded, derr = lde.util.decodeJson(content)
	if not decoded then
		lde.error.raise("Failed to parse " .. configPath .. ": " .. derr)
	end ---@cast decoded -nil

	local newConfig = Package.Config.new(decoded)
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

--- Merges a lockfile entry onto its config entry: lock pins (commit, resolved
--- URLs) win, config-only fields (version for registry deps, optional, features)
--- fill the gaps. The lock entry can't replace the config entry wholesale — a
--- registry dep's version is only in lde.json, so makeNode would lose the
--- source type and fail to classify it.
---@param depInfo lde.Package.Config.Dependency
---@param lockedEntry lde.Lockfile.Dependency
---@return lde.Package.Config.Dependency
local function mergeLockedEntry(depInfo, lockedEntry)
	local merged = {}
	for k, v in pairs(depInfo) do merged[k] = v end
	for k, v in pairs(lockedEntry) do
		if v ~= nil then merged[k] = v end
	end
	return merged
end

function Package:getDependencies()
	local config = self:readConfig()
	local deps = config.dependencies or {}

	local lockfile = self:readLockfile()
	-- A lockfile whose pins don't match the manifest's current declarations
	-- must not override them: the dep re-resolves from lde.json and the next
	-- install rewrites the lockfile (see Lockfile:isStale).
	if not lockfile or lockfile:isStale(config) then return deps end

	-- Prefer locked versions (which have pinned commits) over lde.json,
	-- but preserve config-only flags (optional, features) that aren't stored in the lockfile
	local merged = {}
	for name, depInfo in pairs(deps) do
		local lockedEntry = lockfile:getDependency(name)
		if lockedEntry then
			merged[name] = mergeLockedEntry(depInfo, lockedEntry)
		else
			merged[name] = depInfo
		end
	end
	return merged
end

function Package:getDevDependencies()
	local config = self:readConfig()
	local deps = config.devDependencies or {}

	local lockfile = self:readLockfile()
	if not lockfile or lockfile:isStale(config) then return deps end

	-- Prefer locked versions (which have pinned commits) over lde.json, but
	-- preserve config-only flags (optional, features) that aren't stored in the
	-- lockfile — mirroring getDependencies().
	local merged = {}
	for name, depInfo in pairs(deps) do
		local lockedEntry = lockfile:getDependency(name)
		if lockedEntry then
			merged[name] = mergeLockedEntry(depInfo, lockedEntry)
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

---@param opts { summary: boolean?, isLocked: boolean?, rootExtract: fun()? }?
function Package:installDevDependencies(opts)
	return self:installDependencies(self:getDevDependencies(), nil, nil, opts)
end

Package.updateDependencies = require("lde-core.package.update")

function Package:updateDevDependencies()
	return self:updateDependencies(self:getDevDependencies())
end

Package.bundle = require("lde-core.package.bundle")
Package.compile = require("lde-core.package.compile")
Package.bloat = require("lde-core.package.bloat")
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
---@param isCapture boolean? # If true, isCapture stdout/stderr instead of inheriting them
---@param args string[]? # Extra args appended to the script command (e.g. from `-- <args>`)
---@return boolean?
---@return string?
function Package:runScript(name, isCapture, args)
	local scripts = self:readConfig().scripts
	if not scripts or not scripts[name] then
		lde.error.raise("No script named '" .. name .. "' in lde.json")
	end ---@cast scripts -nil
	local opts = { cwd = self:getDir() }
	if not isCapture then
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
