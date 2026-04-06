local fs = require("fs")
local git = require("git")
local json = require("json")
local path = require("path")
local process = require("process2")
local semver = require("semver")
local lde = require("lde-core")
local ansi = require("ansi")
local Archive = require("archive")

local global = {}
package.loaded[(...)] = global

global.getConfig = require("lde-core.global.config")
global.currentVersion = "0.8.1"

---@class lde.Portfile
---@field name string
---@field git string
---@field versions table<string, string> # version -> commit hash
---@field branch string?
---@field description string?
---@field license string?
---@field authors string[]?
---@field dependencies table<string, string>?

---@param s string
local function sanitize(s)
	return (string.gsub(s, "[^%w_%-]", "_"))
end

---@type string?
local dirOverride = nil

---@param dir string?
function global.setDir(dir)
	dirOverride = dir
end

function global.getDir()
	if dirOverride then return dirOverride end
	local home = os.getenv("HOME") or os.getenv("USERPROFILE")
	return path.join(home, ".lde")
end

function global.getConfigPath()
	return path.join(global.getDir(), "config.json")
end

function global.getGitCacheDir()
	return path.join(global.getDir(), "git")
end

function global.getTarCacheDir()
	return path.join(global.getDir(), "tar")
end

function global.getRockspecCacheDir()
	return path.join(global.getDir(), "rockspecs")
end

function global.getToolsDir()
	return path.join(global.getDir(), "tools")
end

function global.getMingwDir()
	return path.join(global.getDir(), "mingw")
end

function global.getGCCBin()
	if jit.os == "Windows" then
		local mingwGcc = path.join(global.getMingwDir(), "bin", "gcc.exe")
		if fs.exists(mingwGcc) then
			return mingwGcc
		end
	end

	return "gcc"
end

function global.getRegistryDir()
	return path.join(global.getDir(), "registry")
end

-- Only sync once per process invocation
local registrySynced = false

--- Clones the registry if not present, otherwise pulls to update.
--- A failed pull (e.g. offline) is non-fatal; cached data is used.
function global.syncRegistry()
	if registrySynced then return end
	registrySynced = true

	local registryDir = global.getRegistryDir()
	if not fs.exists(registryDir) then
		local ok, err = git.clone(global.getConfig().registry, registryDir)
		if not ok then
			error("Failed to clone lde registry: " .. (err or "unknown error"))
		end
	else
		git.pull(registryDir)
	end
end

---@param name string
---@return lde.Portfile?
---@return string? err
function global.lookupRegistryPackage(name)
	local portfilePath = path.join(global.getRegistryDir(), "packages", name .. ".json")
	local content = fs.read(portfilePath)
	if not content then
		return nil, "Package '" .. name .. "' not found in lde registry"
	end
	return json.decode(content), nil
end

--- Resolves a version string (or nil for latest) to a commit hash.
---@param portfile lde.Portfile
---@param version string? # nil means latest
---@return string version
---@return string commit
function global.resolveRegistryVersion(portfile, version)
	local versions = portfile.versions
	if not versions then
		error("Package '" .. portfile.name .. "' has no versions in registry")
	end

	if version then
		local commit = versions[version]
		if not commit then
			error("Version '" .. version .. "' of '" .. portfile.name .. "' not found in lde registry")
		end
		return version, commit
	end

	-- Find highest semver
	local latest = nil
	for v in pairs(versions) do
		if latest == nil or semver.compare(v, latest) > 0 then
			latest = v
		end
	end

	if not latest then
		error("No versions available for package '" .. portfile.name .. "'")
	end

	return latest, versions[latest]
end

--- Builds the cache directory name for a git repo.
--- Format: name, name-branch, or name-branch-commit
---@param repoName string
---@param branch string?
---@param commit string?
---@return string
function global.getGitRepoDir(repoName, branch, commit)
	local parts = { sanitize(repoName) }

	if branch then
		parts[#parts + 1] = sanitize(branch)
	end

	if commit then
		parts[#parts + 1] = sanitize(commit)
	end

	local fullName = table.concat(parts, "-")
	return path.join(global.getGitCacheDir(), fullName)
end

---@param repoName string
---@param repoUrl string
---@param branch string?
---@param commit string?
function global.cloneDir(repoName, repoUrl, branch, commit)
	local repoDir = global.getGitRepoDir(repoName, branch, commit)
	return git.clone(repoUrl, repoDir, branch, commit)
end

---@param repoName string
---@param repoUrl string
---@param branch string?
---@param commit string?
function global.getOrInitGitRepo(repoName, repoUrl, branch, commit)
	local repoDir = global.getGitRepoDir(repoName, branch, commit)
	if not fs.exists(repoDir) then
		local p = lde.verbose and
			ansi.progress("Cloning " .. repoName .. " " .. ansi.format("{gray}(" .. repoUrl .. ")")) or nil
		local ok, err = global.cloneDir(repoName, repoUrl, branch, commit)
		if not ok then
			if p then p:fail("Cloning " .. repoName) end
			error("Failed to clone git repository: " .. err)
		end
		if p then p:done("Cloned " .. repoName) end
	end

	return repoDir
end

--- Downloads and extracts an archive URL (.zip, .tar.gz, .tar.bz2, etc.) into the cache.
--- Uses `tar -xf` which auto-detects format on all platforms (bsdtar on Windows 10+).
---@param url string
---@return string dir
function global.getOrInitArchive(url)
	local key = sanitize(url)
	local archiveDir = path.join(global.getTarCacheDir(), key)
	if not fs.exists(archiveDir) then
		local label = "Downloading " .. (url:match("([^/]+)$") or url)
		local p = lde.verbose and ansi.progress(label) or nil
		fs.mkdir(archiveDir)

		local archiveFile = archiveDir .. ".archive"

		local code, _, stderr = process.exec("curl", { "-sL", "-o", archiveFile, url })
		if code ~= 0 then
			if p then p:fail(label) end
			error("Failed to download archive '" .. url .. "': " .. (stderr or ""))
		end

		local code2, err2
		if url:match("%.src%.rock$") then
			-- .src.rock is a zip with no single top-level dir; extract directly
			local ok
			ok, err2 = Archive.new(archiveFile):extract(archiveDir)
			code2 = ok and 0 or 1
		else
			local ok
			ok, err2 = Archive.new(archiveFile):extract(archiveDir, { stripComponents = true })
			code2 = ok and 0 or 1
		end

		if code2 ~= 0 then
			fs.rmdir(archiveDir)
			fs.delete(archiveFile)
			if p then p:fail(label) end
			error("Failed to extract archive '" .. url .. "': " .. (err2 or ""))
		end

		fs.delete(archiveFile)
		if p then p:done(label) end
	end
	return archiveDir
end

--- Parses a GitHub /tree/<branch> URL into a clone URL and branch.
---@param url string
---@return string cloneUrl
---@return string? branch
function global.parseGitUrl(url)
	local base, branch = url:match("^(https://github%.com/[^/]+/[^/]+)/tree/(.+)$")
	if base and branch then
		return base .. ".git", branch
	end
	return url, nil
end

--- Derives a cache-friendly repo name from a git URL.
---@param url string
---@return string
function global.repoNameFromUrl(url)
	return url:match("([^/]+)%.git$") or url:match("([^/]+)$")
end

--- Clones or retrieves a cached git repo directory (simple name+branch key, no commit).
---@param repoName string
---@param cloneUrl string
---@param branch string?
---@return string repoDir
function global.getOrCloneRepo(repoName, cloneUrl, branch)
	local safeName = branch and (repoName .. "-" .. branch) or repoName
	local repoDir = global.getGitRepoDir(safeName)
	if not fs.exists(repoDir) then
		local ok, err = git.clone(cloneUrl, repoDir, branch)
		if not ok then
			error("Failed to clone git repository: " .. (err or "unknown error"))
		end
	end
	return repoDir
end

--- Finds a named package inside a directory by scanning for lde.json files.
---@param dir string
---@param name string
---@return lde.Package? pkg
---@return string? err
function global.findNamedPackageIn(dir, name)
	for _, config in ipairs(fs.scan(dir, "**" .. path.separator .. "lde.json")) do
		local parentDir = path.join(dir, path.dirname(config))
		local pkg = lde.Package.open(parentDir)
		if pkg and pkg:getName() == name then
			return pkg, nil
		end
	end

	return nil, "No package named '" .. name .. "' found in: " .. dir
end

--- Writes the platform-appropriate wrapper script into ~/.lde/tools/.
---@param toolName string
---@param packageDir string
---@param packageName string
function global.writeWrapper(toolName, packageDir, packageName)
	local toolsDir = global.getToolsDir()
	local invocation = packageDir
		and ("lde x --path '" .. packageDir .. "' " .. packageName)
		or ("lde x " .. packageName)

	if jit.os == "Windows" then
		local wrapperPath = path.join(toolsDir, toolName .. ".cmd")
		local winInvocation = packageDir
			and ('lde x --path \\"' .. packageDir .. '\\" ' .. packageName)
			or ("lde x " .. packageName)

		if not fs.write(wrapperPath, "@echo off\n" .. winInvocation .. " %*\n") then
			error("Failed to write wrapper script: " .. wrapperPath)
		end

		ansi.printf("{green}Installed tool '%s' -> %s", toolName, wrapperPath)
	else
		local wrapperPath = path.join(toolsDir, toolName)

		if not fs.write(wrapperPath, "#!/bin/sh\nexec " .. invocation .. ' "$@"\n') then
			error("Failed to write wrapper script: " .. wrapperPath)
		end

		local child, err = process.spawn("chmod", { "+x", wrapperPath })
		if not child then
			error("Failed to make wrapper executable: " .. (err or "unknown error"))
		end
		child:wait()

		ansi.printf("{green}Installed tool '%s' -> %s", toolName, wrapperPath)
	end
end

local MINGW_URL = "https://github.com/lde-org/mingw-dist/releases/download/latest/mingw-windows-x86-64.7z"
local SEVENZ_URL = "https://github.com/lde-org/mingw-dist/releases/download/latest/7zr.exe"

--- Ensures a MinGW toolchain exists at ~/.lde/mingw (Windows only).
--- Downloads 7zr.exe temporarily to extract the .7z archive.
function global.ensureMingw()
	if jit.os ~= "Windows" then return end
	if jit.arch ~= "x64" then return end

	local mingwDir = global.getMingwDir()
	if fs.exists(path.join(mingwDir, "bin", "gcc.exe")) then return end

	-- If gcc is already available on PATH, no need to download
	local code = process.exec("gcc", { "--version" })
	if code == 0 then return end

	local p1 = lde.verbose and ansi.progress("Downloading 7zr.exe") or nil

	local tmpDir = path.join(global.getDir(), "mingw-tmp")
	fs.mkdir(tmpDir)

	local sevenzPath = path.join(tmpDir, "7zr.exe")
	local archivePath = path.join(tmpDir, "mingw.7z")

	local code, _, stderr = process.exec("curl", { "-sL", "-o", sevenzPath, SEVENZ_URL })
	if code ~= 0 then
		fs.rmdir(tmpDir)
		if p1 then p1:fail() end
		error("Failed to download 7zr.exe: " .. (stderr or ""))
	end
	if p1 then p1:done() end

	local p2 = lde.verbose and ansi.progress("Downloading MinGW toolchain") or nil
	code, _, stderr = process.exec("curl", { "-sL", "-o", archivePath, MINGW_URL })
	if code ~= 0 then
		fs.rmdir(tmpDir)
		if p2 then p2:fail() end
		error("Failed to download MinGW archive: " .. (stderr or ""))
	end
	if p2 then p2:done() end

	local p3 = lde.verbose and ansi.progress("Extracting MinGW toolchain") or nil
	fs.mkdir(mingwDir)
	code, _, stderr = process.exec(sevenzPath, { "x", archivePath, "-o" .. mingwDir, "-y" })
	fs.rmdir(tmpDir)
	if code ~= 0 then
		fs.rmdir(mingwDir)
		if p3 then p3:fail() end
		error("Failed to extract MinGW archive: " .. (stderr or ""))
	end

	-- The 7z contains a single top-level folder (mingw64); flatten it
	local entries = fs.readdir(mingwDir)
	local first = entries and entries()
	if first and first.type == "dir" then
		local inner = path.join(mingwDir, first.name)
		local finalDir = mingwDir .. "_swap"
		fs.move(inner, finalDir)
		fs.rmdir(mingwDir)
		fs.move(finalDir, mingwDir)
	end

	if p3 then p3:done("Extracted MinGW toolchain") end
end

function global.init()
	local dir = global.getDir()
	if not fs.exists(dir) then
		fs.mkdir(dir)
	end

	local gitCacheDir = global.getGitCacheDir()
	if not fs.exists(gitCacheDir) then
		fs.mkdir(gitCacheDir)
	end

	local tarCacheDir = global.getTarCacheDir()
	if not fs.exists(tarCacheDir) then
		fs.mkdir(tarCacheDir)
	end

	local rockspecCacheDir = global.getRockspecCacheDir()
	if not fs.exists(rockspecCacheDir) then
		fs.mkdir(rockspecCacheDir)
	end

	local toolsDir = global.getToolsDir()
	if not fs.exists(toolsDir) then
		fs.mkdir(toolsDir)
	end
end

return global
