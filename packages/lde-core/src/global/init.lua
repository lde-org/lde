local fs = require("fs")
local git2 = require("git2-sys")
local json = require("json")
local path = require("path")
local process = require("process")
local semver = require("semver")
local lde = require("lde-core")
local ansi = require("ansi")
local env = require("env")
local Archive = require("archive")
local curl = require("curl-sys")

local global = {}
package.loaded[(...)] = global

global.getConfig = require("lde-core.global.config")
global.currentVersion = "0.9.1"

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

--- Returns "github", "gitlab", or nil if the URL is not a recognized git host.
---@param url string
---@return string?
local function isRecognizedGitHost(url)
	if url:match("^https?://github%.com/") then return "github" end
	if url:match("^https?://gitlab%.com/") then return "gitlab" end
	return nil
end

--- Builds a tarball URL for a recognized git host at a given ref.
---@param url string  # git clone URL (may have .git suffix or /tree/... paths)
---@param ref string  # commit SHA, branch name, or tag
---@param hostType string  # "github" or "gitlab"
---@return string
local function buildTarballUrl(url, ref, hostType)
	local base = url:gsub("%.git$", "")
	base = base:gsub("/tree/.*$", "")
	base = base:gsub("/$", "")

	if hostType == "github" then
		return base .. "/archive/" .. ref .. ".tar.gz"
	elseif hostType == "gitlab" then
		local repoName = base:match("/([^/]+)$")
		return base .. "/-/archive/" .. ref .. "/" .. repoName .. "-" .. ref .. ".tar.gz"
	end

	error("Unknown host type: " .. hostType)
end

--- Downloads and extracts a git tarball for a recognized host into repoDir.
---@param url string
---@param commit string
---@param hostType string
---@param repoDir string
---@param label string
local function downloadTarball(url, commit, hostType, repoDir, label)
	local tarballUrl = buildTarballUrl(url, commit, hostType)
	local bar = lde.verbose and ansi.ProgressBar("Downloading " .. label) or nil
	fs.mkdir(repoDir)

	local archiveFile = repoDir .. ".archive"

	local dlOpts
	if bar then
		dlOpts = {
			progress = function(dltotal, dlnow)
				local ratio = dltotal > 0 and (dlnow / dltotal) or nil
				local info = dltotal > 0
					and (ansi.formatBytes(dlnow) .. " / " .. ansi.formatBytes(dltotal))
					or ansi.formatBytes(dlnow)
				bar:update(ratio, info)
			end
		}
	end

	local ok, dlErr = curl.download(tarballUrl, archiveFile, dlOpts)
	if not ok then
		fs.rmdir(repoDir)
		fs.delete(archiveFile)
		if bar then bar:fail("Downloading " .. label) end
		error("Failed to download " .. tarballUrl .. ": " .. (dlErr or ""))
	end

	local ok2, err2 = Archive.new(archiveFile):extract(repoDir, { stripComponents = true })
	fs.delete(archiveFile)

	if not ok2 then
		fs.rmdir(repoDir)
		if bar then bar:fail("Downloading " .. label) end
		error("Failed to extract " .. label .. ": " .. (err2 or ""))
	end

	if bar then bar:done("Downloaded " .. label) end
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
	local override = env.var("SEA_CC")
	if override then
		return override
	end

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
		local repo, err = git2.clone(global.getConfig().registry, registryDir)
		if not repo then
			error("Failed to clone lde registry: " .. (err or "unknown error"))
		end
		repo:updateSubmodules()
	else
		local repo = git2.open(registryDir)
		if repo then repo:pull() end
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

--- Builds the cache directory name for a git repo: <name>-<commit>.
---@param repoName string
---@param commit string
---@return string
function global.getGitRepoDir(repoName, commit)
	return path.join(global.getGitCacheDir(), sanitize(repoName) .. "-" .. sanitize(commit))
end

--- Git clone fallback for unrecognized hosts. Always checks out the specific commit.
---@param repoName string
---@param repoUrl string
---@param commit string
---@param progress fun(stats: table)?
function global.cloneDir(repoName, repoUrl, commit, progress)
	local repoDir = global.getGitRepoDir(repoName, commit)
	local repo, err = git2.clone(repoUrl, repoDir, nil, nil, progress)
	if not repo then return nil, err end
	repo:updateSubmodules(nil, progress)
	local ok, cerr = repo:checkout(commit)
	if not ok then return nil, cerr end
	return true
end

--- Ensures a git repo is cached locally (via tarball for GitHub/GitLab, git clone otherwise).
--- Always resolves to a specific commit. Returns the cache directory and the pinned commit.
---@param repoName string
---@param repoUrl string
---@param branch string?
---@param commit string?
---@return string repoDir
---@return string commit
function global.getOrInitGitRepo(repoName, repoUrl, branch, commit)
	if not commit then
		local ref = branch and ("refs/heads/" .. branch) or "HEAD"
		local sha, err = git2.lsRemote(repoUrl, ref)
		if not sha then
			error("Failed to resolve '" .. ref .. "' for " .. repoUrl .. ": " .. (err or ""))
		end
		commit = sha
	end

	local repoDir = global.getGitRepoDir(repoName, commit)
	if not fs.exists(repoDir) then
		local hostType = isRecognizedGitHost(repoUrl)
		if hostType then
			downloadTarball(repoUrl, commit, hostType, repoDir, repoName)
		else
			local progress
			local bar = lde.verbose and ansi.ProgressBar("Cloning " .. repoName) or nil
			if bar then
				local totalObjs = 0
				progress = function(stats)
					if stats.total_objects > 0 then
						totalObjs = stats.total_objects
					end
					local ratio = totalObjs > 0 and (stats.indexed_objects / totalObjs) or nil
					local info = totalObjs > 0
						and string.format("%d/%d objects", stats.indexed_objects, totalObjs)
						or string.format("%d objects, %s", stats.received_objects, ansi.formatBytes(stats.received_bytes))
					bar:update(ratio, info)
				end
			end
			local ok, err = global.cloneDir(repoName, repoUrl, commit, progress)
			if not ok then
				if bar then bar:fail("Cloning " .. repoName) end
				error("Failed to clone git repository: " .. err)
			end
			if bar then bar:done("Cloned " .. repoName) end
		end
	end

	return repoDir, commit
end

--- Downloads and extracts an archive URL (.zip, .tar.gz, .tar.bz2, etc.) into the cache.
--- Uses `tar -xf` which auto-detects format on all platforms (bsdtar on Windows 10+).
---@param url string
---@return string dir
function global.getOrInitArchive(url)
	local key = sanitize(url)
	local archiveDir = path.join(global.getTarCacheDir(), key)
	if not fs.exists(archiveDir) then
		local filename = url:match("([^/]+)$") or url
		local bar = lde.verbose and ansi.ProgressBar("Downloading " .. filename) or nil
		fs.mkdir(archiveDir)

		local archiveFile = archiveDir .. ".archive"

		local dlOpts
		if bar then
			dlOpts = {
				progress = function(dltotal, dlnow)
					local ratio = dltotal > 0 and (dlnow / dltotal) or nil
					local info = dltotal > 0
						and (ansi.formatBytes(dlnow) .. " / " .. ansi.formatBytes(dltotal))
						or ansi.formatBytes(dlnow)
					bar:update(ratio, info)
				end
			}
		end

		local ok, dlErr = curl.download(url, archiveFile, dlOpts)
		if not ok then
			if bar then bar:fail("Downloading " .. filename) end
			error("Failed to download archive '" .. url .. "': " .. (dlErr or ""))
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
			if bar then bar:fail("Downloading " .. filename) end
			error("Failed to extract archive '" .. url .. "': " .. (err2 or ""))
		end

		fs.delete(archiveFile)
		if bar then bar:done("Downloaded " .. filename) end
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

--- Clones or retrieves a cached git repo directory. Always resolves to the latest commit.
---@param repoName string
---@param cloneUrl string
---@param branch string?
---@return string repoDir
---@return string commit
function global.getOrCloneRepo(repoName, cloneUrl, branch)
	local ref = branch and ("refs/heads/" .. branch) or "HEAD"
	local commit, err = git2.lsRemote(cloneUrl, ref)
	if not commit then
		error("Failed to resolve ref for " .. cloneUrl .. ": " .. (err or ""))
	end

	local repoDir = global.getGitRepoDir(repoName, commit)
	if not fs.exists(repoDir) then
		local hostType = isRecognizedGitHost(cloneUrl)
		if hostType then
			downloadTarball(cloneUrl, commit, hostType, repoDir, repoName)
		else
			local repo, cerr = git2.clone(cloneUrl, repoDir, branch)
			if not repo then
				error("Failed to clone git repository: " .. (cerr or "unknown error"))
			end
			repo:updateSubmodules()
			local ok, cerr2 = repo:checkout(commit)
			if not ok then
				error("Failed to checkout commit: " .. (cerr2 or "unknown error"))
			end
		end
	end
	return repoDir, commit
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

	local p1 = lde.verbose and ansi.ProgressBar("Downloading 7zr.exe") or nil

	local tmpDir = path.join(global.getDir(), "mingw-tmp")
	fs.mkdir(tmpDir)

	local sevenzPath = path.join(tmpDir, "7zr.exe")
	local archivePath = path.join(tmpDir, "mingw.7z")

	local dlOpts1
	if p1 then
		dlOpts1 = {
			progress = function(dltotal, dlnow)
				local ratio = dltotal > 0 and (dlnow / dltotal) or nil
				local info = dltotal > 0
					and (ansi.formatBytes(dlnow) .. " / " .. ansi.formatBytes(dltotal))
					or ansi.formatBytes(dlnow)
				p1:update(ratio, info)
			end
		}
	end
	local ok, dlErr = curl.download(SEVENZ_URL, sevenzPath, dlOpts1)
	if not ok then
		fs.rmdir(tmpDir)
		if p1 then p1:fail("Downloading 7zr.exe") end
		error("Failed to download 7zr.exe: " .. (dlErr or ""))
	end
	if p1 then p1:done("Downloaded 7zr.exe") end

	local p2 = lde.verbose and ansi.ProgressBar("Downloading MinGW toolchain") or nil
	local dlOpts2
	if p2 then
		dlOpts2 = {
			progress = function(dltotal, dlnow)
				local ratio = dltotal > 0 and (dlnow / dltotal) or nil
				local info = dltotal > 0
					and (ansi.formatBytes(dlnow) .. " / " .. ansi.formatBytes(dltotal))
					or ansi.formatBytes(dlnow)
				p2:update(ratio, info)
			end
		}
	end
	local ok2, dlErr2 = curl.download(MINGW_URL, archivePath, dlOpts2)
	if not ok2 then
		fs.rmdir(tmpDir)
		if p2 then p2:fail("Downloading MinGW toolchain") end
		error("Failed to download MinGW archive: " .. (dlErr2 or ""))
	end
	if p2 then p2:done("Downloaded MinGW toolchain") end

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
