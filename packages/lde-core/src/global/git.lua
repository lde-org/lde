--- Git cache: clone/checkout, host tarball downloads, ref resolution.

const fs = require("fs")
const path = require("path")
const ansi = require("ansi")
const util = require("util")

const lde = require("lde-core")
const dirs = require("lde-core.global.dirs")
const consts = require("lde-core.global.consts")
const curl = util.lazy(|| -> require("curl-sys"))
const Archive = util.lazy(|| -> require("archive"))
const git2 = util.lazy(|| -> require("git2-sys"))

local M = {}

--- Suffix that keeps a temp cache dir private to this process (tostring of a
--- fresh table yields its address, which is unique while the table lives).
local function uniqueSuffix()
	return tostring({}):match("0x(%x+)$") or tostring(os.time())
end

--- Returns "github", "gitlab", "codeberg", "bitbucket", or nil if the URL is
--- not a recognized git host (hosts with archive endpoints for tarball downloads).
---@param url string
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
	error("unreachable", 0)
end

--- Downloads and extracts a git tarball for a recognized host into repoDir.
---@param url string
---@param commit string
---@param hostType string
---@param repoDir string
---@param label string
local function downloadTarball(url, commit, hostType, repoDir, label)
	local tarballUrl = buildTarballUrl(url, commit, hostType)
	local bar = lde.isVerbose ? ansi.progress("Downloading " .. label) : nil
	-- mkdirAll: namespaced names nest the cache dir (git/ns/pkg-<commit>).
	fs.mkdirAll(repoDir)

	-- Per-process download path: two installs fetching the same repo must not
	-- write (and truncate) the same file.
	local archiveFile = repoDir .. ".archive" .. uniqueSuffix()

	local dlOpts = { timeout = consts.DOWNLOAD_TIMEOUT }
	if bar then
		dlOpts.progress = function(dltotal, dlnow)
			local ratio = dltotal > 0 ? dlnow / dltotal : nil
			local info = dltotal > 0
				and (ansi.formatBytes(dlnow) .. " / " .. ansi.formatBytes(dltotal))
				or ansi.formatBytes(dlnow)
			bar:update(ratio, info)
		end
	end

	local ok, dlErr = curl().download(tarballUrl, archiveFile, dlOpts)
	if not ok then
		fs.rmdir(repoDir)
		fs.delete(archiveFile)
		if bar then bar:fail("Downloading " .. label) end
		lde.error.raise("Failed to download " .. tarballUrl .. ": " .. (dlErr or ""))
	end

	-- Extract into a sibling temp dir and move it into place: a concurrent
	-- install of the same repo must never see a half-extracted cache dir.
	const tmpDir = repoDir .. ".tmp" .. uniqueSuffix()
	local ok2, err2 = Archive().new(archiveFile):extract(tmpDir, { stripComponents = true })
	fs.delete(archiveFile)

	if not ok2 then
		fs.rmdir(tmpDir)
		fs.rmdir(repoDir)
		if bar then bar:fail("Downloading " .. label) end
		lde.error.raise("Failed to extract " .. label .. ": " .. (err2 or ""))
	end

	if not fs.move(tmpDir, repoDir) then
		fs.rmdir(tmpDir)
		if not fs.exists(repoDir) then
			if bar then bar:fail("Downloading " .. label) end
			lde.error.raise("Failed to move extracted repo into " .. repoDir)
		end
	end

	M.markGitRepoCached(repoDir)
	if bar then bar:done("Downloaded " .. label) end
end

--- Builds the cache directory name for a git repo: <name>-<commit>.
--- Namespaced names (ns/pkg) nest the cache dir (git/ns/pkg-<commit>) instead
--- of flattening, so they can't collide with a flat package named ns_pkg. The
--- "/" is normalized to the OS separator so the nested path is platform-consistent.
---@param repoName string
---@param commit string
function M.getGitRepoDir(repoName, commit)
	const safeName = (repoName:gsub("[^%w_%-/]", "_"):gsub("/", path.separator))
	return path.join(dirs.getGitCacheDir(), safeName .. "-" .. dirs.sanitize(commit))
end

--- Mark a git cache dir as fully materialized. Existence alone is not proof
--- of a complete download: a dir created by an interrupted extract or clone
--- must be re-fetched, not trusted.
---@param repoDir string
function M.markGitRepoCached(repoDir)
	fs.mkdirAll(repoDir)
	fs.write(path.join(repoDir, consts.CACHE_MARKER), "")
end

--- Whether a git cache dir is usable: it exists and either carries the
--- completion marker (written after a successful extract/clone) or still
--- yields the named package (legacy dirs materialized before the marker
--- existed — adopted here so later runs skip the scan). A dir that fails both
--- checks is a partial leftover from an interrupted run.
---@param repoDir string
---@param packageName string
---@return boolean
function M.isGitRepoCached(repoDir, packageName)
	if not fs.exists(repoDir) then return false end
	local marker = path.join(repoDir, consts.CACHE_MARKER)
	if fs.exists(marker) then return true end
	-- Note: `require("util")` here is packages/util (dedent/hash/lazy), not
	-- lde-core's util — the named-package scan lives on lde.util.
	local pkg = lde.util.findNamedPackage(repoDir, packageName)
	if pkg then
		fs.write(marker, "")
		return true
	end
	return false
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
	-- Clone into a sibling temp dir and move it into place, so a concurrent
	-- install never opens a half-cloned repo from the cache.
	if fs.exists(repoDir) then
		local cached = git2().open(repoDir)
		if cached then return cached end
		fs.rmdir(repoDir)
	end
	const tmpDir = repoDir .. ".tmp" .. uniqueSuffix()
	fs.rmdir(tmpDir)

	local repo, err = git2().clone(repoUrl, tmpDir, branch, 1, progress)
	if not repo and branch then
		repo, err = git2().clone(repoUrl, tmpDir, nil, 1, progress)
	end
	if not repo and err and err:find("shallow", 1, true) then
		-- Only reachable when every shallow attempt failed for lack of shallow
		-- support, which also means checkout_branch was moot — a plain full
		-- clone works and the caller pins the exact commit afterwards.
		repo, err = git2().clone(repoUrl, tmpDir, nil, nil, progress)
	end
	if not repo then
		fs.rmdir(tmpDir)
		return nil, "clone failed: " .. tostring(err)
	end

	if not fs.move(tmpDir, repoDir) then
		fs.rmdir(tmpDir)
		local won = fs.exists(repoDir) and git2().open(repoDir)
		if not won then
			return nil, "failed to move cloned repo into " .. repoDir
		end
		return won, nil
	end
	return git2().open(repoDir), nil
end

--- Git clone fallback for unrecognized hosts. Shallow (depth=1), no submodules,
--- always checks out the specific commit.
---@param repoName string
---@param repoUrl string
---@param commit string
---@param branch string?
---@param progress fun(stats: table)?
function M.cloneDir(repoName, repoUrl, commit, branch, progress)
	local repoDir = M.getGitRepoDir(repoName, commit)
	local repo, err = shallowClone(repoUrl, repoDir, branch, progress)
	if not repo then return nil, err end
	local ok, cerr = repo:checkout(commit)
	if not ok then return nil, cerr end
	M.markGitRepoCached(repoDir)
	return true
end

--- Resolve a branch-or-tag ref to a commit sha. Tries the ref as a branch
--- first, then as a (peeled) tag — rockspec `source.tag` values are tags, and
--- annotated tags point at a tag object rather than a commit.
---@param repoUrl string
---@param ref string? -- branch or tag name, or nil/"" for HEAD
local function resolveGitRef(repoUrl, ref)
	if not ref or ref == "" or ref == "HEAD" then
		return git2().lsRemote(repoUrl, "HEAD") --[[@as string?]]
	end

	local sha, err = git2().lsRemote(repoUrl, "refs/heads/" .. ref)
	if sha then return sha --[[@as string]] end
	-- Tags: prefer the peeled "^{}" entry (annotated tags), then the raw tag ref
	-- (lightweight tags point straight at the commit).
	sha, err = git2().lsRemote(repoUrl, "refs/tags/" .. ref .. "^{}")
	if sha then return sha --[[@as string]] end
	sha, err = git2().lsRemote(repoUrl, "refs/tags/" .. ref)
	if sha then return sha --[[@as string]] end
	return nil, err
end

-- Reused by `lde add` to validate a git source at add time and pin the
-- resolved commit in the lockfile immediately.
M.resolveGitRef = resolveGitRef

--- Ensures a git repo is cached locally (via tarball for recognized hosts,
--- shallow git clone otherwise). Always resolves to a specific commit.
--- With `offline`, never touches the network: the commit must be given and the
--- repo must already be in the cache, otherwise it errors.
--- Returns the cache directory and the pinned commit.
---@param repoName string
---@param repoUrl string
---@param branch string?
---@param commit string?
---@param isOffline boolean?
function M.getOrInitGitRepo(repoName, repoUrl, branch, commit, isOffline)
	if not commit then
		if isOffline then
			lde.error.raise("offline: cannot resolve '" .. (branch or "HEAD") .. "' for " .. repoUrl)
		end
		local sha, err = resolveGitRef(repoUrl, branch)
		if not sha then
			lde.error.raise("Failed to resolve '" .. (branch or "HEAD") .. "' for " .. repoUrl .. ": " .. (err or ""))
		end
		commit = sha
	end ---@cast commit string

	local repoDir = M.getGitRepoDir(repoName, commit)
	-- A partial cache dir from an interrupted run must not count as cached.
	if fs.exists(repoDir) and not M.isGitRepoCached(repoDir, repoName) then
		fs.rmdir(repoDir)
	end
	if isOffline and not M.isGitRepoCached(repoDir, repoName) then
		lde.error.raise("offline: '" .. repoName .. "' is not cached locally (run once online to cache it)")
	end
	if not M.isGitRepoCached(repoDir, repoName) then
		local hostType = isRecognizedGitHost(repoUrl)
		if hostType then
			downloadTarball(repoUrl, commit, hostType, repoDir, repoName)
		else
			local progress
			local bar = lde.isVerbose ? ansi.progress("Cloning " .. repoName) : nil
			if bar then
				local totalObjs = 0
				progress = function(stats)
					if stats.total_objects > 0 then
						totalObjs = stats.total_objects
					end
					local ratio = totalObjs > 0 ? stats.indexed_objects / totalObjs : nil
					local info = totalObjs > 0
						and string.format("%d/%d objects", stats.indexed_objects, totalObjs)
						or string.format("%d objects, %s", stats.received_objects, ansi.formatBytes(stats.received_bytes))
					bar:update(ratio, info)
				end
			end
			local ok, err = M.cloneDir(repoName, repoUrl, commit, branch, progress)
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
function M.planGitRepo(repoName, repoUrl, branch, commit)
	if not commit then
		local sha, err = resolveGitRef(repoUrl, branch)
		if not sha then
			lde.error.raise("Failed to resolve '" .. (branch or "HEAD") .. "' for " .. repoUrl .. ": " .. (err or ""))
		end
		commit = sha
	end ---@cast commit string

	local repoDir = M.getGitRepoDir(repoName, commit)
	-- The parallel download writes the tarball to repoDir .. ".archive", so the
	-- (possibly nested, for namespaced names) parent must already exist.
	local parent = path.dirname(repoDir)
	if not fs.isdir(parent) then fs.mkdirAll(parent) end
	-- Heal a partial cache dir from an interrupted run: existence alone must
	-- not count as "cached", or the walk trusts a half-extracted tree and
	-- fails with "No lde.json with name '<name>' found in: <dir>".
	if fs.exists(repoDir) and not M.isGitRepoCached(repoDir, repoName) then
		fs.rmdir(repoDir)
	end
	const plan = { dir = repoDir, commit = commit }

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

--- Extract a downloaded git tarball into its repo cache dir. On success the
--- dir is marked complete (see consts.CACHE_MARKER); on failure the partial dir
--- is removed so a later run re-downloads instead of trusting a
--- half-extracted tree.
---@param archiveFile string
---@param repoDir string
---@return boolean? ok
---@return string? err
function M.extractGitTarball(archiveFile, repoDir)
	local ok, err = Archive().new(archiveFile):extract(repoDir, { stripComponents = true })
	fs.delete(archiveFile)
	if ok then
		M.markGitRepoCached(repoDir)
	else
		fs.rmdir(repoDir)
	end
	return ok, err
end

--- Parses a GitHub /tree/<branch> URL into a clone URL and branch.
---@param url string
---@return string cloneUrl
---@return string? branch
function M.parseGitUrl(url)
	local base, branch = url:match("^(https://github%.com/[^/]+/[^/]+)/tree/(.+)$")
	if base and branch then
		return base .. ".git", branch
	end
	return url, nil
end

--- Derives a cache-friendly repo name from a git URL.
---@param url string
---@return string
function M.repoNameFromUrl(url)
	return url:match("([^/]+)%.git$") or url:match("([^/]+)$")
end

--- Opens the git repository enclosing `dir`, walking up its parent directories.
--- git2.open needs the repository or workdir path itself, so a package that
--- lives in a subdirectory of its repository (monorepo) would fail there.
---@param dir string
---@return git2.Repo?, string?
function M.openEnclosingRepo(dir)
	local repoPath, err = git2().discover(dir)
	if not repoPath then return nil, err end
	return git2().open(repoPath)
end

--- Clones or retrieves a cached git repo directory. Always resolves to the latest commit.
---@param repoName string
---@param cloneUrl string
---@param branch string?
function M.getOrCloneRepo(repoName, cloneUrl, branch)
	local commit, err = resolveGitRef(cloneUrl, branch)
	if not commit then
		lde.error.raise("Failed to resolve ref for " .. cloneUrl .. ": " .. (err or ""))
	end ---@cast commit string

	local repoDir = M.getGitRepoDir(repoName, commit)
	-- A partial cache dir from an interrupted run must not count as cached.
	if fs.exists(repoDir) and not M.isGitRepoCached(repoDir, repoName) then
		fs.rmdir(repoDir)
	end
	if not M.isGitRepoCached(repoDir, repoName) then
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
			M.markGitRepoCached(repoDir)
		end
	end
	return repoDir, commit
end

--- Finds a named package inside a directory by scanning for lde.json files.
---@param dir string
---@param name string
---@return lde.Package? pkg
---@return string? err
function M.findNamedPackageIn(dir, name)
	for _, config in ipairs(fs.scan(dir, "**" .. path.separator .. "lde.json")) do
		const parentDir = path.join(dir, path.dirname(config))
		local pkg = lde.Package.open(parentDir)
		if pkg and pkg:getName() == name then
			return pkg, nil
		end
	end

	return nil, "No package named '" .. name .. "' found in: " .. dir
end

return M
