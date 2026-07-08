-- This file implements a 'mini' lde for the sake of bootstrapping an initial lde binary for a platform without requiring lde.
-- Dependencies:
--  - All: curl, tar
--  - Windows: Developer Mode or Administrator

local separator = package.config:sub(1, 1)

local function join(...)
	return table.concat({ ... }, separator)
end

local isWindows = separator == '\\'

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
	os.execute(isWindows and ('mkdir "' .. dir .. '"') or ('mkdir -p "' .. dir .. '"'))
end

---@type fun(src: string, dest: string)
local function mklink(src, dest)
	if exists(dest) then return end
	os.execute(
		isWindows and ('mklink /D "' .. dest .. '" "' .. src .. '"')
		or ("ln -sf '" .. src .. "' '" .. dest .. "'")
	)
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
	return readhandle(io.open(path, "r"))
end

---@type fun(path: string, content: string)
local function write(path, content)
	local file = io.open(path, "w")
	if not file then return end
	file:write(content)
	file:close()
end

---@type fun(path: string)
local function rm(path)
	os.execute(isWindows and ('rmdir /S /Q "' .. path .. '"') or ('rm -rf "' .. path .. '"'))
end

---@type fun(src: string, dest: string) # Recursive copy
local function copy(src, dest)
	if not exists(src) then return end

	os.execute(
		isWindows and ('xcopy /E /I /Y "' .. src .. '" "' .. dest .. '"')
		or ('cp -rL "' .. src .. '" "' .. dest .. '"')
	)
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

local tmpBase = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
local tmpLDEDir = join(tmpBase, "lde")

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

---@param packagePath string
---@param targetDir string
local function buildPackage(packagePath, targetDir)
	local config = jsonDecode(assert(read(join(packagePath, "lde.json")) or read(join(packagePath, "lpm.json")),
		"No lde.json at " .. packagePath)) --[[@as { name: string, dependencies: { [string]: minilde.dep } }]]

	mkdir(targetDir)
	if exists(join(packagePath, "build.lua")) then
		local outputDir = join(targetDir, config.name)

		copy(join(packagePath, "src"), outputDir)
		setenv("LDE_OUTPUT_DIR", outputDir)
		setenv("LPM_OUTPUT_DIR", outputDir)

		---@alias minilde.build { outDir: string }

		---@class minilde.build
		local build = {}
		build.__index = build

		---@format disable-next
		do
			function build:fetch(url) return assert(readhandle(io.popen("curl -sL " .. url)), "failed to fetch " .. url) end
			function build:write(rel, content) write(join(outputDir, rel), content) end
			function build:read(rel) return read(join(outputDir, rel)) end
			function build:extract(rel, dest) mkdir(join(outputDir, dest)); os.execute('tar --force-local -xzf "' .. join(outputDir, rel) .. '" -C "' .. join(outputDir, dest) .. '"') end
			function build:copy(rel, dest) copy(join(outputDir, rel), join(outputDir, dest)) end
			function build:delete(rel) rm(join(outputDir, rel)) end
			function build:move(rel, dest) os.rename(join(outputDir, rel), join(outputDir, dest)) end
			function build:exists(rel) return exists(join(outputDir, rel)) end
			function build:sh(cmd)
				local res = os.execute(cmd)
				assert(res == 0 or res == true, "failed to execute " .. cmd)
			end
			function build:cc(args)
				local compiler = os.getenv("SEA_CC") or os.getenv("CC") or "gcc"
				local cmd = compiler .. " " .. table.concat(args, " ")
				local res = os.execute(cmd)
				assert(res == 0 or res == true, "cc failed: " .. cmd)
			end
		end

		package.loaded["lde-build"] = setmetatable({ outDir = outputDir }, build)

		local oldDir = getcwd()
		chdir(packagePath)
		dofile(join(packagePath, "build.lua"))
		chdir(oldDir)
	else
		mklink(join(packagePath, "src"), join(targetDir, config.name))
	end

	if not config.dependencies then return end

	for name, dep in pairs(config.dependencies) do
		---@format disable-next
		if dep.path then
			buildPackage(join(packagePath, dep.path), targetDir)
		elseif dep.git then -- downloads to tmpLDEDir/<name> then build to target
			local finalDir = join(tmpLDEDir, "git", name)
			if not exists(finalDir) then
				local tarballUrl = dep.git .. "/archive/master.tar.gz"
				local tarball = join(tmpLDEDir, "tar", name)
				local curlOk = os.execute('curl -fsSL "' .. tarballUrl .. '" -o "' .. tarball .. '"')
				assert(curlOk == 0 or curlOk == true,
					"failed to download " .. tarballUrl)
				mkdir(finalDir)
				-- --force-local prevents tar from treating drive letters (C:) as remote hosts
				local tarOk = os.execute('tar --force-local -xzf "' .. tarball .. '" --strip-components=1 -C "' .. finalDir .. '"')
				assert(tarOk == 0 or tarOk == true,
					"failed to extract tarball for " .. name .. " — repo may use submodules (not supported in bootstrap mode)")
			end

			buildPackage(finalDir, targetDir)
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

if pop() == "run" then
	local config = assert(build())

	local cwd = getcwd()
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
