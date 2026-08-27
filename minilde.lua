-- This file implements a 'mini' lde for the sake of bootstrapping an initial lde binary for a platform without requiring lde.
-- Dependencies:
--  - All: curl, tar
--  - Windows: Developer Mode or Administrator

local separator = package.config:sub(1, 1)

local function join(...)
	return table.concat({ ... }, separator)
end

local isWindows = separator == '\\'

-- On Windows, os.execute uses cmd.exe which doesn't understand Unix commands.
-- Use _spawnlp to invoke bash directly, bypassing cmd.exe entirely.
-- _P_WAIT = 2 (suspends caller until child exits, returns child exit code).
local function sh(cmd)
	if isWindows then
		local ffi = require("ffi")
		pcall(ffi.cdef, [[int _spawnlp(int mode, const char *cmdname, const char *arg0, ...);]])
		-- bash uses forward slashes; convert backslashes in the command string
		cmd = cmd:gsub("\\", "/")
		local _P_WAIT = 2
		return ffi.C._spawnlp(_P_WAIT, "bash", "bash", "-c", cmd, ffi.cast("char *", nil))
	end
	return os.execute(cmd)
end

---@param path string
local function exists(path)
	local ok, _, code = os.rename(path, path)
	if not ok then
		return code == 13 -- permission denied means it exists
	end

	return true
end

---@param dir string
local function mkdir(dir)
	if exists(dir) then return end
	sh('mkdir -p "' .. dir .. '"')
end

---@type fun(src: string, dest: string)
local function mklink(src, dest)
	if exists(dest) then return end
	sh("ln -sf '" .. src .. "' '" .. dest .. "'")
end

---@type fun(handle: file*?): string?
local function readhandle(handle)
	if not handle then return end
	local content = handle:read("*a")
	handle:close()
	return content
end

---@type fun(path: string): string?
local function read(path)
	return readhandle(io.open(path, "rb"))
end

---@type fun(path: string, content: string)
local function write(path, content)
	local file = io.open(path, "wb")
	if not file then return end
	file:write(content)
	file:close()
end

---@type fun(path: string)
local function rm(path)
	sh('rm -rf "' .. path .. '"')
end

---@type fun(src: string, dest: string) # Recursive copy
local function copy(src, dest)
	if not exists(src) then return end
	sh('cp -rL "' .. src .. '" "' .. dest .. '"')
end

---@type fun(b: string): any? # Tiny json decoder with very basic support for what we will use in lde.json files
local function jsonDecode(b)
	local c = 0; local function d(e)
		local f, g, m = b:find("^%s*", c)
		if f then c = g + 1 end; f, g, m = b:find(e, c)
		if f then
			c = g + 1; return m or true
		end
	end; local h, i; local function j()
		local n = d("^(%d+%.?%d*)"); if n then return tonumber(n) end
		return d("^\"([^\"]*)\"") or h() or i() or d("^true") or (d("^false") and false)
	end; function h()
		if not d("^{") then return end; local k = {}
		while not d("^}") do
			local l = d("^\"([^\"]*)\"")
			d("^:"); k[l] = j(); d("^,")
		end; return k
	end; function i()
		if not d("^%[") then return end; local k = {}
		while not d("^%]") do
			k[#k + 1] = j()
			d("^,")
		end; return k
	end; return h()
end

local args = { ... }
local function pop() return table.remove(args, 1) end

---@alias minilde.dep
--- | { path: string }
--- | { git: string }
--- | { version: string, name?: string } # registry: name defaults to the dep key, version resolved via portfile

local tmpBase = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
local tmpLDEDir = join(tmpBase, "lde")

local registryUrl = "https://raw.githubusercontent.com/lde-org/registry/master/packages/"

---@type fun(url: string): string?
local function httpGet(url)
	local content = readhandle(io.popen('curl -fsSL "' .. url .. '"'))
	return content == "" and nil or content -- curl failures produce empty stdout
end

---@param a string
---@param b string
---@return boolean
local function versionGreater(a, b)
	local pa, pb = {}, {}
	for part in a:gmatch("%d+") do pa[#pa + 1] = tonumber(part) end
	for part in b:gmatch("%d+") do pb[#pb + 1] = tonumber(part) end
	for i = 1, math.max(#pa, #pb) do
		local x, y = pa[i] or 0, pb[i] or 0
		if x ~= y then return x > y end
	end
	return false
end

--- Downloads a git repo tarball (branch or commit ref) to tmpLDEDir/git/<name>.
---@param name string
---@param url string
---@param ref string
---@return string finalDir
local function fetchGitRepo(name, url, ref)
	url = url:gsub("%.git$", "")

	local finalDir = join(tmpLDEDir, "git", name)
	if not exists(finalDir) then
		local tarballUrl = url .. "/archive/" .. ref .. ".tar.gz"
		local tarball = join(tmpLDEDir, "tar", name)
		local curlOk = sh('curl -fsSL "' .. tarballUrl .. '" -o "' .. tarball .. '"')
		assert(curlOk == 0 or curlOk == true, "failed to download " .. tarballUrl)
		mkdir(finalDir)

		-- On Windows, bsdtar misparses drive letters (C:) as remote hosts.
		-- Use pushd to cd into the dest dir so neither -f nor -C see a drive letter path.
		local tarOk = sh('tar -xzf "' .. tarball .. '" --strip-components=1 -C "' .. finalDir .. '"')
		assert(tarOk == 0 or tarOk == true, "failed to extract tarball for " .. name .. " — repo may use submodules (not supported in bootstrap mode)")
	end

	return finalDir
end

local ffi = require("ffi")
local setenv ---@type fun(name: string, value: string)
local chdir ---@type fun(dir: string)
local getcwd ---@type fun(): string
ffi.cdef [[void _exit(int status);]]
if isWindows then
	ffi.cdef [[int _putenv_s(const char *name, const char *value);]]
	setenv = function(name, value) ffi.C._putenv_s(name, value) end
	ffi.cdef [[int _chdir(const char *dirname);]]
	chdir = function(dir) ffi.C._chdir(dir) end
	ffi.cdef [[int _getcwd(char *buffer, size_t size);]]
	getcwd = function()
		local buffer = ffi.new("char[?]", 1024)
		ffi.C._getcwd(buffer, 1024)
		return ffi.string(buffer)
	end
else
	ffi.cdef [[int setenv(const char *name, const char *value, int overwrite);]]
	setenv = function(name, value) ffi.C.setenv(name, value, 1) end
	ffi.cdef [[int chdir(const char *path);]]
	chdir = function(dir) ffi.C.chdir(dir) end
	ffi.cdef [[char *getcwd(char *buf, size_t size);]]
	getcwd = function()
		local buffer = ffi.new("char[?]", 1024)
		ffi.C.getcwd(buffer, 1024)
		return ffi.string(buffer)
	end
end

-- Resolve this script's absolute path: launchers (which re-invoke luajit from
-- an arbitrary cwd) need to point at it, and they're written next to it.
local scriptPath = arg and arg[0] or ""
if not (scriptPath:sub(1, 1) == "/" or scriptPath:match("^%a:")) then
	scriptPath = join(getcwd(), scriptPath)
end

--- Writes a launcher executable that runs `luajit <this script> "$@"`, so
--- lde-core can spawn `minilde __build-pkg ...` during bootstrap: env.execPath()
--- resolves to the luajit binary, which can't take a script argument, so the
--- spawn must go through a script that re-invokes luajit with this file first.
--- Returns the launcher path, or nil when it couldn't be written.
---@return string?
local function ensureLauncher()
	local dir = scriptPath:match("^(.*)[/\\][^/\\]*$") or "."
	local launcher = join(dir, isWindows and "minilde.cmd" or "minilde.sh")
	if isWindows then
		write(launcher, "@echo off\r\nluajit \"" .. scriptPath .. "\" %*\r\nexit /b %errorlevel%\r\n")
	else
		local quoted = scriptPath:gsub("'", "'\\''")
		write(launcher, "#!/bin/sh\nexec luajit '" .. quoted .. "' \"$@\"\n")
		sh('chmod +x "' .. launcher .. '"')
	end
	return exists(launcher) and launcher or nil
end

--- Runs a package's build.lua with an lde-build context bound to outputDir.
--- Does not copy src or recurse into dependencies (the caller handles those).
---@param packagePath string
---@param outputDir string
---@return boolean ok
---@return string? err
local function runBuildScript(packagePath, outputDir)
	setenv("LDE_OUTPUT_DIR", outputDir)
	setenv("LPM_OUTPUT_DIR", outputDir)

	---@alias minilde.build { outDir: string }

	---@class minilde.build
	local build = {}
	build.__index = build

	---@format disable-next
	do
		function build:fetch(url)
			return assert(httpGet(url), "failed to fetch " .. url)
		end
		function build:write(rel, content) write(join(outputDir, rel), content) end
		function build:read(rel) return read(join(outputDir, rel)) end
		function build:extract(rel, dest)
			mkdir(join(outputDir, dest))
			local src = join(outputDir, rel)
			local dst = join(outputDir, dest)
			sh('tar -xzf "' .. src .. '" -C "' .. dst .. '"')
		end
		function build:copy(rel, dest) copy(join(outputDir, rel), join(outputDir, dest)) end
		function build:delete(rel) rm(join(outputDir, rel)) end
		function build:move(rel, dest) os.rename(join(outputDir, rel), join(outputDir, dest)) end
		function build:exists(rel) return exists(join(outputDir, rel)) end
		function build:sh(cmd)
			local res = sh(cmd)
			assert(res == 0 or res == true, "failed to execute " .. cmd)
		end
		function build:cc(args)
			local cc = os.getenv("SEA_CC") or os.getenv("CC") or ""
			local compiler = cc ~= "" and cc or "gcc"
			local cmd = compiler .. " " .. table.concat(args, " ")
			local res = sh(cmd)
			assert(res == 0 or res == true, "cc failed: " .. cmd)
		end
	end

	package.loaded["lde-build"] = setmetatable({ outDir = outputDir }, build)

	local oldDir = getcwd()
	chdir(packagePath)
	local ok, err = pcall(dofile, join(packagePath, "build.lua"))
	chdir(oldDir)
	return ok, err
end

---@param packagePath string
---@param targetDir string
---@param alias string # install name in targetDir: the require key for deps, the package name for the root
local function buildPackage(packagePath, targetDir, alias)
	local config = jsonDecode(assert(read(join(packagePath, "lde.json")) or read(join(packagePath, "lpm.json")),
		"No lde.json at " .. packagePath)) --[[@as { name: string, dependencies: { [string]: minilde.dep } }]]
	alias = alias or config.name

	mkdir(targetDir)
	if exists(join(packagePath, "build.lua")) then
		local outputDir = join(targetDir, alias)

		copy(join(packagePath, "src"), outputDir)
		local ok, err = runBuildScript(packagePath, outputDir)
		if not ok then error(err or "build failed", 0) end
	else
		mklink(join(packagePath, "src"), join(targetDir, alias))
	end

	if not config.dependencies then return end

	for name, dep in pairs(config.dependencies) do
		---@format disable-next
		if dep.path then
			buildPackage(join(packagePath, dep.path), targetDir, name)
		elseif dep.git then -- downloads to tmpLDEDir/git/<name> then build to target
			buildPackage(fetchGitRepo(name, dep.git, "master"), targetDir, name)
		elseif dep.version then -- registry: portfile maps the version to a git repo + commit
			local packageName = dep.name or name
			local portfileUrl = registryUrl .. packageName .. ".json"
			local portfile = assert(jsonDecode(assert(httpGet(portfileUrl), "failed to fetch " .. portfileUrl)), "invalid portfile for " .. packageName)
			local versions = portfile.versions or {}

			---@type string?
			local commit
			if dep.version ~= "latest" then
				commit = versions[dep.version]
				assert(commit, "version '" .. dep.version .. "' of '" .. packageName .. "' not found in lde registry")
			else
				local best
				for v in pairs(versions) do
					if not best or versionGreater(v, best) then best = v end
				end
				commit = best and versions[best]
				assert(commit, "no versions available for package '" .. packageName .. "'")
			end

			local gitUrl = assert(portfile.git, "portfile for '" .. packageName .. "' has no git URL")
			buildPackage(fetchGitRepo(name, gitUrl, commit), targetDir, name)
		else
			error("Unknown dependency type: " .. name)
		end
	end

	return config
end

local function build()
	mkdir(tmpLDEDir)
	mkdir(join(tmpLDEDir, "tar"))
	mkdir(join(tmpLDEDir, "git"))

	local cwd = getcwd()
	return buildPackage(cwd, join(cwd, "target"))
end

if #args == 0 then
	print("Usage: minilde [-C <dir>] <command>")
	print("Commands:")
	print("  run: build and run the package")

	return
end

-- -C <dir>: change working directory before doing anything
if args[1] == "-C" then
	table.remove(args, 1)
	local dir = assert(table.remove(args, 1), "minilde: -C requires a directory argument")
	pcall(ffi.cdef, isWindows and "int _chdir(const char *path);" or "int chdir(const char *path);")
	local chdir = isWindows and ffi.C._chdir or ffi.C.chdir
	assert(chdir(dir) == 0, "minilde: -C: cannot chdir to '" .. dir .. "'")
end

local command = pop()

-- Hidden build worker, mirroring `lde __build-pkg <pkgDir> <outDir> [<target>]`.
-- lde-core spawns it with env.execPath() to overlap native builds; under
-- bootstrap that resolves to luajit + this script, so the route must exist here.
if command == "__build-pkg" then
	local pkgDir = assert(pop(), "__build-pkg: missing package dir")
	local outDir = assert(pop(), "__build-pkg: missing output dir")
	pop() -- target name: bootstrap compiles for the host, so ignore it
	if not exists(join(pkgDir, "build.lua")) then
		io.stderr:write("__build-pkg: no build.lua at " .. pkgDir .. "\n")
		os.exit(1)
	end
	mkdir(outDir)
	local ok, err = runBuildScript(pkgDir, outDir)
	if not ok then
		io.stderr:write(tostring(err) .. "\n")
		os.exit(1)
	end
	return
end

if command == "run" then
	local config = assert(build())

	-- lde-core spawns its build worker with env.execPath(); during bootstrap
	-- that is the luajit binary, which can't take a script argument. Point it
	-- at our launcher so the worker becomes `minilde __build-pkg ...`.
	local launcher = ensureLauncher()
	if launcher then setenv("LDE_BIN", launcher) end

	local cwd = getcwd()
	write(join(cwd, "target", ".skip"), "") -- tell lde to skip building

	package.path = join(cwd, "target", "?.lua") .. ";" ..
		join(cwd, "target", "?", "init.lua") .. ";" ..
		package.path
	package.cpath = join(cwd, "target", "?.so") .. ";" ..
		join(cwd, "target", "?.dll") .. ";" ..
		join(cwd, "target", "?.dylib") .. ";" ..
		package.cpath

	local extraArgs = {}
	local foundSep = false
	for _, v in ipairs(args) do
		if foundSep then
			extraArgs[#extraArgs + 1] = v
		elseif v == "--" then
			foundSep = true
		end
	end
	_G.arg = extraArgs

	local chunk = loadfile(join(cwd, "target", config.name, "init.lua"))
	if chunk then
		chunk(unpack(extraArgs))
	end

	-- TODO: Figure out why luajit cleanup causes a segfault without this
	ffi.C._exit(0)
end
