local fs = require("fs")
local json = require("json")
local path = require("path")
local process = require("process")
local semver = require("semver")
local lde = require("lde-core")
local ansi = require("ansi")
local env = require("env")
local util = require("util")

local global = {}
package.loaded[(...)] = global

-- Lazily wrap native modules to avoid loading them (which uses a ton of memory and adds some overhead to copy the file)
-- This isn't done with require() inline because that would cause issues with LuaJIT compilation.
local curl = util.lazy(function() return require("curl-sys") end)
local Archive = util.lazy(function() return require("archive") end)
local git2 = util.lazy(function() return require("git2-sys") end)

global.getConfig = require("lde-core.global.config")
global.currentVersion = (function()
	local ok, v = pcall(require, "lde.version")
	return ok and v or "0.10.0"
end)()

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
	if not s then return "" end
	return (string.gsub(s, "[^%w_%-]", "_"))
end

--- Returns "github", "gitlab", "codeberg", "bitbucket", or nil if the URL is
--- not a recognized git host (hosts with archive endpoints for tarball downloads).
---@param url string
---@return string?
local function isRecognizedGitHost(url)
	if url:match("^https?://github%.com/") then return "github" end
	if url:match("^https?://gitlab%.com/") then return "gitlab" end
	if url:match("^https?://codeberg%.org/") then return "codeberg" end
	if url:match("^https?://bitbucket%.org/") then return "bitbucket" end
	return nil
end

--- Builds a tarball URL for a recognized git host at a given ref.
---@param url string  # git clone URL (may have .git suffix or /tree/... paths)
---@param ref string  # commit SHA, branch name, or tag
---@param hostType string  # "github", "gitlab", "codeberg", or "bitbucket"
---@return string
local function buildTarballUrl(url, ref, hostType)
	local base = url:gsub("%.git$", "")
	base = base:gsub("/tree/.*$", "")
	base = base:gsub("/$", "")

	if hostType == "github" or hostType == "codeberg" then
		-- GitHub and Codeberg (Forgejo/Gitea) both serve /archive/<ref>.tar.gz
		return base .. "/archive/" .. ref .. ".tar.gz"
	elseif hostType == "gitlab" then
		local repoName = base:match("/([^/]+)$")
		return base .. "/-/archive/" .. ref .. "/" .. repoName .. "-" .. ref .. ".tar.gz"
	elseif hostType == "bitbucket" then
		return base .. "/get/" .. ref .. ".tar.gz"
	end

	lde.error.raise("Unknown host type: " .. hostType)
end

--- Downloads and extracts a git tarball for a recognized host into repoDir.
---@param url string
---@param commit string
---@param hostType string
---@param repoDir string
---@param label string
local function downloadTarball(url, commit, hostType, repoDir, label)
	local tarballUrl = buildTarballUrl(url, commit, hostType)
	local bar = lde.verbose and ansi.progress("Downloading " .. label) or nil
	-- mkdirAll: namespaced names nest the cache dir (git/ns/pkg-<commit>).
	fs.mkdirAll(repoDir)

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

	local ok, dlErr = curl().download(tarballUrl, archiveFile, dlOpts)
	if not ok then
		fs.rmdir(repoDir)
		fs.delete(archiveFile)
		if bar then bar:fail("Downloading " .. label) end
		lde.error.raise("Failed to download " .. tarballUrl .. ": " .. (dlErr or ""))
	end

	local ok2, err2 = Archive().new(archiveFile):extract(repoDir, { stripComponents = true })
	fs.delete(archiveFile)

	if not ok2 then
		fs.rmdir(repoDir)
		if bar then bar:fail("Downloading " .. label) end
		lde.error.raise("Failed to extract " .. label .. ": " .. (err2 or ""))
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
	return path.join(os.getenv("HOME") or os.getenv("USERPROFILE"), ".lde")
end

--- The user-level lde directory, independent of any --tree override. Global
--- registry metadata (the luarocks manifest, the resolved-URL cache) lives
--- here so per-tree installs share it instead of re-downloading per tree.
function global.getUserDir()
	return path.join(os.getenv("HOME") or os.getenv("USERPROFILE"), ".lde")
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

function global.getCCBin()
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

--- Returns the make binary used for builds.
--- On Windows, prefers the bundled mingw toolchain's mingw32-make (the
--- conventional name there) and falls back to the bare name so a make on
--- PATH is used when no toolchain is installed.
---@return string
function global.getMakeBin()
	if jit.os == "Windows" then
		local mingwMake = path.join(global.getMingwDir(), "bin", "mingw32-make.exe")
		if fs.exists(mingwMake) then
			return mingwMake
		end
		local makeExe = path.join(global.getMingwDir(), "bin", "make.exe")
		if fs.exists(makeExe) then
			return makeExe
		end
		return "mingw32-make"
	end

	return "make"
end

--- Returns the shell used to run lde.json scripts and shell commands. On
--- Windows, prefers the bundled toolchain's BusyBox sh so scripts get POSIX
--- semantics (positional args, quoting) on every platform; falls back to
--- cmd.exe when no toolchain is installed.
---@return string bin
---@return string flag
---@return boolean isCmd # true when the shell is cmd.exe (double-quote escaping)
function global.getScriptShell()
	if jit.os == "Windows" then
		local shExe = path.join(global.getMingwDir(), "bin", "sh.exe")
		if fs.exists(shExe) then
			return shExe, "-c", false
		end
		return "cmd", "/c", true
	end
	return "sh", "-c", false
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
		local repo, err = git2().clone(global.getConfig().registry, registryDir)
		if not repo then
			lde.error.raise("Failed to clone lde registry: " .. (err or "unknown error"))
		end
		repo:updateSubmodules()
	else
		local repo = git2().open(registryDir)
		if repo then repo:pull() end
	end
end

--- Validates a package name against the lde registry naming rules (mirrors
--- schemas/registry.schema.json in the lde-org/registry repo):
---
---   * flat ("foo") or exactly one namespace level ("ns/foo")
---   * lowercase only; parts use a-z, 0-9, _ and - (no dots, no "..")
---   * each part starts with a letter and ends with a letter or digit
---   * the namespace part is at least 3 characters
---   * the full name is at most 128 characters
---
---@param name string
---@return string? err # nil when the name is valid
function global.validatePackageName(name)
	if type(name) ~= "string" or name == "" then
		return "package name cannot be empty"
	end
	if #name > 128 then
		return "package name '" .. name .. "' is too long (max 128 characters)"
	end
	if name:find("..", 1, true) then
		return "package name '" .. name .. "' is invalid: must not contain '..'"
	end
	if name:sub(1, 1) == "/" or name:sub(-1) == "/" then
		return "package name '" .. name .. "' is invalid: must not start or end with '/'"
	end

	local ns, pkg = name:match("^([^/]+)/([^/]+)$")
	if not ns then
		pkg = name
		if name:find("/", 1, true) then
			return "package name '" .. name .. "' is invalid: a namespace is exactly one level deep (e.g. ns/foo)"
		end
	end

	---@param part string
	---@return boolean
	local function partValid(part)
		return part:match("^[a-z][a-z0-9_-]*[a-z0-9]$") ~= nil
			or part:match("^[a-z]$") ~= nil
	end

	if not partValid(pkg) then
		return "package name '" .. name .. "' is invalid: it must be lowercase, start with a letter, end with a letter or digit, and contain only a-z, 0-9, _ and -"
	end
	if ns then
		if #ns < 3 then
			return "namespace '" .. ns .. "' must be at least 3 characters"
		end
		if not partValid(ns) then
			return "namespace '" .. ns .. "' is invalid: it must be lowercase, start with a letter, end with a letter or digit, and contain only a-z, 0-9, _ and -"
		end
	end
	return nil
end

---@param name string
---@return lde.Portfile?
---@return string? err
function global.lookupRegistryPackage(name)
	local nameErr = global.validatePackageName(name)
	if nameErr then
		return nil, "Invalid package name '" .. tostring(name) .. "': " .. nameErr
	end

	-- Namespaced names (ns/foo) live at packages/ns/foo.json; split on "/" and
	-- re-join with the OS separator so nested lookups work on Windows too.
	local relPath = (name:gsub("/", path.separator))
	local portfilePath = path.join(global.getRegistryDir(), "packages", relPath .. ".json")
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
		lde.error.raise("Package '" .. portfile.name .. "' has no versions in registry")
	end

	if version then
		local commit = versions[version]
		if not commit then
			lde.error.raise("Version '" .. version .. "' of '" .. portfile.name .. "' not found in lde registry")
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
		lde.error.raise("No versions available for package '" .. portfile.name .. "'")
	end

	return latest, versions[latest]
end

--- Builds the cache directory name for a git repo: <name>-<commit>.
--- Namespaced names (ns/pkg) nest the cache dir (git/ns/pkg-<commit>) instead
--- of flattening, so they can't collide with a flat package named ns_pkg. The
--- "/" is normalized to the OS separator so the nested path is platform-consistent.
---@param repoName string
---@param commit string
---@return string
function global.getGitRepoDir(repoName, commit)
	local safeName = (repoName:gsub("[^%w_%-/]", "_"):gsub("/", path.separator))
	return path.join(global.getGitCacheDir(), safeName .. "-" .. sanitize(commit))
end

--- Shallow (depth=1) clone without submodules. `branch` may be nil (default
--- branch) or a branch name. Retries:
---  1. If `branch` names a tag instead (rockspec source.tag), libgit2's
---     checkout_branch only accepts branch names — retry on the default branch.
---  2. Transports without shallow support (e.g. the local transport for
---     file:///path deps) get a full clone. The caller still checks out the
---     exact commit either way.
---@param repoUrl string
---@param repoDir string
---@param branch string?
---@param progress fun(stats: table)?
---@return any? repo
---@return string? err
local function shallowClone(repoUrl, repoDir, branch, progress)
	-- Namespaced repo names nest the cache dir (git/ns/pkg-<commit>); libgit2
	-- does not create missing parents, so make sure they exist up front.
	local parent = path.dirname(repoDir)
	if not fs.isdir(parent) then fs.mkdirAll(parent) end
	local repo, err = git2().clone(repoUrl, repoDir, branch, 1, progress)
	if not repo and branch then
		repo, err = git2().clone(repoUrl, repoDir, nil, 1, progress)
	end
	if not repo and err and err:find("shallow", 1, true) then
		-- Only reachable when every shallow attempt failed for lack of shallow
		-- support, which also means checkout_branch was moot — a plain full
		-- clone works and the caller pins the exact commit afterwards.
		repo, err = git2().clone(repoUrl, repoDir, nil, nil, progress)
	end
	return repo, err
end

--- Git clone fallback for unrecognized hosts. Shallow (depth=1), no submodules,
--- always checks out the specific commit.
---@param repoName string
---@param repoUrl string
---@param commit string
---@param branch string?
---@param progress fun(stats: table)?
function global.cloneDir(repoName, repoUrl, commit, branch, progress)
	local repoDir = global.getGitRepoDir(repoName, commit)
	local repo, err = shallowClone(repoUrl, repoDir, branch, progress)
	if not repo then return nil, err end
	local ok, cerr = repo:checkout(commit)
	if not ok then return nil, cerr end
	return true
end

--- Resolve a branch-or-tag ref to a commit sha. Tries the ref as a branch
--- first, then as a (peeled) tag — rockspec `source.tag` values are tags, and
--- annotated tags point at a tag object rather than a commit.
---@param repoUrl string
---@param ref string? -- branch or tag name, or nil/"" for HEAD
---@return string? sha
---@return string? err
local function resolveGitRef(repoUrl, ref)
	if not ref or ref == "" or ref == "HEAD" then
		return git2().lsRemote(repoUrl, "HEAD")
	end

	local sha, err = git2().lsRemote(repoUrl, "refs/heads/" .. ref)
	if sha then return sha end
	-- Tags: prefer the peeled "^{}" entry (annotated tags), then the raw tag ref
	-- (lightweight tags point straight at the commit).
	sha, err = git2().lsRemote(repoUrl, "refs/tags/" .. ref .. "^{}")
	if sha then return sha end
	sha, err = git2().lsRemote(repoUrl, "refs/tags/" .. ref)
	if sha then return sha end
	return nil, err
end

--- Ensures a git repo is cached locally (via tarball for recognized hosts,
--- shallow git clone otherwise). Always resolves to a specific commit.
--- With `offline`, never touches the network: the commit must be given and the
--- repo must already be in the cache, otherwise it errors.
--- Returns the cache directory and the pinned commit.
---@param repoName string
---@param repoUrl string
---@param branch string?
---@param commit string?
---@param offline boolean?
---@return string repoDir
---@return string commit
function global.getOrInitGitRepo(repoName, repoUrl, branch, commit, offline)
	if not commit then
		if offline then
			lde.error.raise("offline: cannot resolve '" .. (branch or "HEAD") .. "' for " .. repoUrl)
		end
		local sha, err = resolveGitRef(repoUrl, branch)
		if not sha then
			lde.error.raise("Failed to resolve '" .. (branch or "HEAD") .. "' for " .. repoUrl .. ": " .. (err or ""))
		end
		commit = sha
	end

	local repoDir = global.getGitRepoDir(repoName, commit)
	if offline and not fs.exists(repoDir) then
		lde.error.raise("offline: '" .. repoName .. "' is not cached locally (run once online to cache it)")
	end
	if not fs.exists(repoDir) then
		local hostType = isRecognizedGitHost(repoUrl)
		if hostType then
			downloadTarball(repoUrl, commit, hostType, repoDir, repoName)
		else
			local progress
			local bar = lde.verbose and ansi.progress("Cloning " .. repoName) or nil
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
			local ok, err = global.cloneDir(repoName, repoUrl, commit, branch, progress)
			if not ok then
				if bar then bar:fail("Cloning " .. repoName) end
				lde.error.raise("Failed to clone git repository: " .. err)
			end
			if bar then bar:done("Cloned " .. repoName) end
		end
	end

	return repoDir, commit
end

--- Phase 1 of cached git-repo materialization: resolve the commit (lsRemote if
--- needed) and compute where the repo tarball must be downloaded to.
--- The tarball itself is not downloaded here — callers enqueue it into the
--- parallel download session (or fall back to `getOrInitGitRepo`).
---@param repoName string
---@param repoUrl string
---@param branch string?
---@param commit string?
---@return lde.install.GitPlan
function global.planGitRepo(repoName, repoUrl, branch, commit)
	if not commit then
		local sha, err = resolveGitRef(repoUrl, branch)
		if not sha then
			lde.error.raise("Failed to resolve '" .. (branch or "HEAD") .. "' for " .. repoUrl .. ": " .. (err or ""))
		end
		commit = sha
	end

	local repoDir = global.getGitRepoDir(repoName, commit)
	-- The parallel download writes the tarball to repoDir .. ".archive", so the
	-- (possibly nested, for namespaced names) parent must already exist.
	local parent = path.dirname(repoDir)
	if not fs.isdir(parent) then fs.mkdirAll(parent) end
	local plan = { dir = repoDir, commit = commit }

	if not fs.exists(repoDir) then
		local hostType = isRecognizedGitHost(repoUrl)
		if hostType then
			plan.tarballUrl = buildTarballUrl(repoUrl, commit, hostType)
			plan.archiveFile = repoDir .. ".archive"
		else
			-- unrecognized host: git clone directly (not parallelizable via curl)
			plan.clone = { repoName = repoName, repoUrl = repoUrl, commit = commit, branch = branch }
		end
	end

	return plan
end

--- Extract a downloaded git tarball into its repo cache dir.
---@param archiveFile string
---@param repoDir string
---@return boolean? ok
---@return string? err
function global.extractGitTarball(archiveFile, repoDir)
	local ok, err = Archive().new(archiveFile):extract(repoDir, { stripComponents = true })
	fs.delete(archiveFile)
	return ok, err
end

--- Downloads and extracts an archive URL (.zip, .tar.gz, .tar.bz2, etc.) into the cache.
--- Uses `tar -xf` which auto-detects format on all platforms (bsdtar on Windows 10+).
--- With `offline`, never touches the network: the archive must already be
--- cached, otherwise it errors.
---
--- Failure-safe: a failed download/extract removes the partially-created cache dir
--- so the next run re-downloads instead of trusting an empty/partial dir. A
--- concurrent install may finish (and delete the .archive file) while this
--- download is in flight; the extracted dir is reused in that case.
---@param url string
---@param offline boolean?
---@return string dir
function global.getOrInitArchive(url, offline)
	local archiveDir = global.getArchiveDir(url)
	if offline and not fs.exists(archiveDir) then
		lde.error.raise("offline: archive is not cached locally (run once online to cache it): " .. url)
	end
	if not fs.exists(archiveDir) then
		local filename = url:match("([^/]+)$") or url
		local bar = lde.verbose and ansi.progress("Downloading " .. filename) or nil
		-- Created up front: curl.download opens archiveDir .. ".archive" directly,
		-- so the parent must exist. Removed again on failure (see below).
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

		local function download()
			local ok, dlErr = curl().download(url, archiveFile, dlOpts)
			if not ok then return nil, dlErr end
			if not fs.exists(archiveFile) then
				-- A concurrent install extracted and deleted the .archive file while
				-- we were downloading; reuse its extracted dir when it's ready.
				local iter = fs.readdir(archiveDir)
				if iter then
					for _ in iter do
						return true, nil
					end
				end
				return nil, "download did not produce a file"
			end
			return true, nil
		end

		-- One retry: GitHub release assets redirect to expiring CDN URLs, which
		-- can fail transiently on the first attempt.
		local ok, dlErr = download()
		if not ok then
			ok, dlErr = download()
		end
		if not ok then
			if bar then bar:fail("Downloading " .. filename) end
			-- Don't leave a partial cache dir behind: the next run re-downloads.
			fs.rmdir(archiveDir)
			lde.error.raise("Failed to download archive '" .. url .. "': " .. (dlErr or "unknown error"))
		end

		local ok2, err2 = global.extractArchive(url, archiveFile, archiveDir)
		if not ok2 then
			if bar then bar:fail("Downloading " .. filename) end
			-- Same cleanup on extract failure: an empty/partial dir must not make
			-- every later run skip the download.
			fs.rmdir(archiveDir)
			lde.error.raise("Failed to extract archive '" .. url .. "': " .. (err2 or "unknown error"))
		end

		if bar then bar:done("Downloaded " .. filename) end
	end
	return archiveDir
end

--- Cache directory an archive URL extracts into.
---@param url string
---@return string
function global.getArchiveDir(url)
	return path.join(global.getTarCacheDir(), sanitize(url))
end

--- Extract a downloaded archive file into its cache directory.
---@param url string
---@param archiveFile string
---@param archiveDir string
---@return boolean? ok
---@return string? err
function global.extractArchive(url, archiveFile, archiveDir)
	if not fs.exists(archiveFile) then
		return nil, "missing downloaded archive: " .. archiveFile
	end

	local Archive = Archive()
	local ok, err2
	if url:match("%.src%.rock$") then
		-- .src.rock is a zip with no single top-level dir; extract directly
		ok, err2 = Archive.new(archiveFile):extract(archiveDir)
	else
		ok, err2 = Archive.new(archiveFile):extract(archiveDir, { stripComponents = true })
	end

	fs.delete(archiveFile)
	return ok, err2
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
	local commit, err = resolveGitRef(cloneUrl, branch)
	if not commit then
		lde.error.raise("Failed to resolve ref for " .. cloneUrl .. ": " .. (err or ""))
	end

	local repoDir = global.getGitRepoDir(repoName, commit)
	if not fs.exists(repoDir) then
		local hostType = isRecognizedGitHost(cloneUrl)
		if hostType then
			downloadTarball(cloneUrl, commit, hostType, repoDir, repoName)
		else
			local repo, cerr = shallowClone(cloneUrl, repoDir, branch)
			if not repo then
				lde.error.raise("Failed to clone git repository: " .. (cerr or "unknown error"))
			end
			local ok, cerr2 = repo:checkout(commit)
			if not ok then
				lde.error.raise("Failed to checkout commit: " .. (cerr2 or "unknown error"))
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
--- The `--` separator stops lde's own arg parser from swallowing tool args that
--- start with a dash (e.g. `tl --help`), so they are passed through to the tool.
--- The wrapper execs the exact binary that installed it (env.execPath) rather
--- than a bare `lde`: PATH may resolve to a different (stale) lde — e.g. CI
--- builds a fresh binary named lde-dev while the nightly sits on PATH.
--- Registry/rocks tools run with `--offline`: they're resolved from the cache
--- at ~/.lde and fail if the package isn't cached, instead of updating the
--- registry on every invocation. When the install used a non-default tree
--- (`--tree`), the wrapper embeds it so its offline lookups hit the tree's
--- caches (registry, git, tar) rather than the default user dir.
---@param toolName string
---@param packageDir string? # nil for rocks: tools (resolved from the registry)
---@param packageName string
function global.writeWrapper(toolName, packageDir, packageName)
	local toolsDir = global.getToolsDir()
	local ldeBin = env.execPath() or "lde"
	local treeFlag = ""
	if global.getDir() ~= global.getUserDir() then
		treeFlag = " --tree '" .. global.getDir() .. "'"
	end
	-- sh double-quotes the binary path (spaces), cmd needs its own form below.
	local invocation = packageDir
		and ("\"" .. ldeBin .. "\" x --path '" .. packageDir .. "' " .. packageName .. treeFlag .. " --")
		or ("\"" .. ldeBin .. "\" x" .. treeFlag .. " " .. packageName .. " --offline --")

	if jit.os == "Windows" then
		local wrapperPath = path.join(toolsDir, toolName .. ".cmd")
		-- cmd uses plain double quotes (no backslash escapes like sh), so
		-- paths are wrapped in " directly.
		local winTreeFlag = ""
		if global.getDir() ~= global.getUserDir() then
			winTreeFlag = " --tree \"" .. global.getDir() .. "\""
		end
		local winInvocation = packageDir
			and ('"' .. ldeBin .. '" x --path "' .. packageDir .. '" ' .. packageName .. winTreeFlag .. " --")
			or ('"' .. ldeBin .. '" x' .. winTreeFlag .. " " .. packageName .. " --offline --")

		if not fs.write(wrapperPath, "@echo off\n" .. winInvocation .. " %*\n") then
			lde.error.raise("Failed to write wrapper script: " .. wrapperPath)
		end

		ansi.printf("{green}Installed tool '%s' -> %s", toolName, wrapperPath)
	else
		local wrapperPath = path.join(toolsDir, toolName)

		if not fs.write(wrapperPath, "#!/bin/sh\nexec " .. invocation .. ' "$@"\n') then
			lde.error.raise("Failed to write wrapper script: " .. wrapperPath)
		end

		local child, err = process.spawn("chmod", { "+x", wrapperPath })
		if not child then
			lde.error.raise("Failed to make wrapper executable: " .. (err or "unknown error"))
		end
		child:wait()

		ansi.printf("{green}Installed tool '%s' -> %s", toolName, wrapperPath)
	end
end

local TOOLCHAIN_BASE = "https://github.com/lde-org/toolchain-dist/releases/download/latest"

--- Ensures a toolchain exists at ~/.lde/mingw (Windows only).
--- Downloads a 7z extractor temporarily to extract the .7z archive.
--- Supports x86-64 and aarch64 (ARM64) Windows.
---@param opts? { arch?: string } # override jit.arch for cross-compilation
function global.ensureMingw(opts)
	if jit.os ~= "Windows" then return end

	local arch = (opts and opts.arch) or jit.arch
	-- Map LuaJIT arch to URL arch names
	local urlArch, sevenZArch
	if arch == "x64" then
		urlArch = "x86-64"
		sevenZArch = "x86_64"
	elseif arch == "arm64" then
		urlArch = "aarch64"
		sevenZArch = "aarch64"
	else
		lde.error.raise("Unsupported architecture for toolchain: " .. arch)
	end

	local TOOLCHAIN_URL = TOOLCHAIN_BASE .. "/toolchain-windows-" .. urlArch .. ".7z"
	local SEVENZ_URL = TOOLCHAIN_BASE .. "/7z-" .. sevenZArch .. ".exe"

	local mingwDir = global.getMingwDir()
	if fs.exists(path.join(mingwDir, "bin", "gcc.exe")) then return end

	-- If gcc is already available on PATH, no need to download
	local code = process.exec("gcc", { "--version" })
	if code == 0 then return end

	local p1 = lde.verbose and ansi.progress("Downloading 7z extractor") or nil

	local tmpDir = path.join(global.getDir(), "mingw-tmp")
	fs.mkdir(tmpDir)

	local sevenzPath = path.join(tmpDir, "7z.exe")
	local archivePath = path.join(tmpDir, "toolchain.7z")

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
	local ok, dlErr = curl().download(SEVENZ_URL, sevenzPath, dlOpts1)
	if not ok then
		fs.rmdir(tmpDir)
		if p1 then p1:fail("Downloading 7z extractor") end
		lde.error.raise("Failed to download 7z extractor: " .. (dlErr or ""))
	end
	if p1 then p1:done("Downloaded 7z extractor") end

	local p2 = lde.verbose and ansi.progress("Downloading toolchain") or nil
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
	local ok2, dlErr2 = curl().download(TOOLCHAIN_URL, archivePath, dlOpts2)
	if not ok2 then
		fs.rmdir(tmpDir)
		if p2 then p2:fail("Downloading toolchain") end
		lde.error.raise("Failed to download toolchain archive: " .. (dlErr2 or ""))
	end
	if p2 then p2:done("Downloaded toolchain") end

	local p3 = lde.verbose and ansi.progress("Extracting toolchain") or nil
	fs.mkdir(mingwDir)
	code, _, stderr = process.exec(sevenzPath, { "x", archivePath, "-o" .. mingwDir, "-y" })
	fs.rmdir(tmpDir)
	if code ~= 0 then
		fs.rmdir(mingwDir)
		if p3 then p3:fail() end
		lde.error.raise("Failed to extract toolchain archive: " .. (stderr or ""))
	end

	-- The 7z contains a single top-level folder (toolchain); flatten it
	local entries = fs.readdir(mingwDir)
	local first = entries and entries()
	if first and first.type == "dir" then
		local inner = path.join(mingwDir, first.name)
		local finalDir = mingwDir .. "_swap"
		fs.move(inner, finalDir)
		fs.rmdir(mingwDir)
		fs.move(finalDir, mingwDir)
	end

	if p3 then p3:done("Extracted toolchain") end
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
