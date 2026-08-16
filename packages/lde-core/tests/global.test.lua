-- Unit tests for lde-core.global's offline, pure helpers: cache-dir naming,
-- git URL parsing, and git-repo planning (planGitRepo / getOrInitGitRepo with
-- pinned commits never touch the network). Network-backed paths (registry
-- sync, tarball downloads, cloneDir) are exercised elsewhere via the CLI.
local test = require("lde-test")

local lde = require("lde-core")
local global = lde.global

local fs = require("fs")
local env = require("env")
local path = require("path")

local tmpBase = path.join(env.tmpdir(), "lde-global-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

--
-- Cache directory naming
--

test.it("getGitRepoDir combines sanitized repo name and commit", function()
	local dir = global.getGitRepoDir("middleclass", "abc123")
	test.equal(dir, path.join(global.getGitCacheDir(), "middleclass-abc123"))
end)

test.it("getGitRepoDir sanitizes unsafe characters but keeps namespace slashes", function()
	local dir = global.getGitRepoDir("my/repo name", "x y")
	-- Space -> _, "-" separator, and the "/" nests the cache dir instead of
	-- flattening (so namespaced names can't collide with flat ones).
	test.equal(dir, path.join(global.getGitCacheDir(), "my", "repo_name-x_y"))
end)

test.it("getGitRepoDir nests namespaced names instead of flattening them", function()
	local dir = global.getGitRepoDir("ns/pkg", "abc123")
	test.equal(dir, path.join(global.getGitCacheDir(), "ns", "pkg-abc123"))
end)

test.it("getArchiveDir keys the tar cache by sanitized URL", function()
	local dir = global.getArchiveDir("https://example.com/pkg-1.0.tar.gz")
	test.truthy(dir:find(global.getTarCacheDir() .. path.separator))
	test.truthy(dir:find("pkg%-1_0_tar_gz$"))
end)

test.it("cache subdirectories live under the lde dir", function()
	local root = global.getDir()
	test.equal(global.getGitCacheDir(), path.join(root, "git"))
	test.equal(global.getTarCacheDir(), path.join(root, "tar"))
	test.equal(global.getRockspecCacheDir(), path.join(root, "rockspecs"))
	test.equal(global.getToolsDir(), path.join(root, "tools"))
end)

--
-- Git URL helpers
--

test.it("parseGitUrl extracts the branch from a /tree/ URL", function()
	local cloneUrl, branch = global.parseGitUrl("https://github.com/user/repo/tree/main")
	test.equal(cloneUrl, "https://github.com/user/repo.git")
	test.equal(branch, "main")
end)

test.it("parseGitUrl leaves plain URLs untouched", function()
	local cloneUrl, branch = global.parseGitUrl("https://github.com/user/repo")
	test.equal(cloneUrl, "https://github.com/user/repo")
	test.equal(branch, nil)

	local withGit = global.parseGitUrl("https://github.com/user/repo.git")
	test.equal(withGit, "https://github.com/user/repo.git")
end)

test.it("repoNameFromUrl strips the .git suffix", function()
	test.equal(global.repoNameFromUrl("https://github.com/user/repo.git"), "repo")
	test.equal(global.repoNameFromUrl("https://github.com/user/repo"), "repo")
	test.equal(global.repoNameFromUrl("git@github.com:user/repo.git"), "repo")
end)

--
-- planGitRepo (no downloads: plans only)
--

test.it("planGitRepo pins a tarball plan for recognized hosts", function()
	local plan = global.planGitRepo("mypkg", "https://github.com/user/repo.git", nil, "abc123")
	test.equal(plan.dir, global.getGitRepoDir("mypkg", "abc123"))
	test.equal(plan.commit, "abc123")
	test.truthy(plan.tarballUrl, "github URLs must plan a tarball download")
	test.equal(plan.archiveFile, plan.dir .. ".archive")
	test.falsy(plan.clone)
end)

test.it("planGitRepo builds tarball URLs for codeberg and bitbucket", function()
	local codeberg = global.planGitRepo("mypkg", "https://codeberg.org/user/repo.git", nil, "codeberg123")
	test.equal(codeberg.tarballUrl, "https://codeberg.org/user/repo/archive/codeberg123.tar.gz")
	test.falsy(codeberg.clone)

	local bitbucket = global.planGitRepo("mypkg", "https://bitbucket.org/user/repo", nil, "bitbucket123")
	test.equal(bitbucket.tarballUrl, "https://bitbucket.org/user/repo/get/bitbucket123.tar.gz")
	test.falsy(bitbucket.clone)
end)

test.it("planGitRepo plans a git clone for unrecognized hosts", function()
	local plan = global.planGitRepo("mypkg", "/tmp/some/repo", "dev", "abc123")
	test.truthy(plan.clone, "local/unknown hosts must plan a git clone")
	test.equal(plan.clone.repoName, "mypkg")
	test.equal(plan.clone.repoUrl, "/tmp/some/repo")
	test.equal(plan.clone.commit, "abc123")
	test.equal(plan.clone.branch, "dev")
	test.falsy(plan.tarballUrl)
end)

test.it("planGitRepo returns no content plan when the repo is already cached", function()
	local commit = "cached123"
	local repoDir = global.getGitRepoDir("cachedpkg", commit)
	fs.rmdir(repoDir)
	fs.mkdirAll(repoDir)

	local plan = global.planGitRepo("cachedpkg", "https://github.com/user/repo.git", nil, commit)
	test.equal(plan.dir, repoDir)
	test.falsy(plan.tarballUrl, "cached repos must not plan a download")
	test.falsy(plan.clone)
end)

--
-- getOrInitGitRepo with a warm cache (no network)
--

test.it("getOrInitGitRepo returns the cached dir without resolving anything", function()
	local commit = "warmcached123"
	local repoDir = global.getGitRepoDir("warmpkg", commit)
	fs.rmdir(repoDir)
	fs.mkdirAll(repoDir)

	local dir, resolved = global.getOrInitGitRepo("warmpkg", "https://example.com/repo.git", nil, commit)
	test.equal(dir, repoDir)
	test.equal(resolved, commit, "the pinned commit must be used as-is")
end)
