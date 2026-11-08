-- Dependency-node tests that stay offline: registry portfiles are written into
-- a fake LDE_HOME tree and point at non-existent hosts, so only source
-- identity and the git plan are exercised (no clone, no download).
const test = require("lde-test")

const fs = require("fs")
const env = require("env")
local path = require("path")
const json = require("json")

const nodeModel = require("lde-core.package.install.node")

local tmpBase = path.join(env.tmpdir(), "lde-node-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

--- Writes a portfile into a fake registry tree under `treeDir`.
---@param treeDir string
---@param portfile table
local function writeRegistry(treeDir, portfile)
	const pkgPath = path.join(treeDir, "registry", "packages", portfile.name .. ".json")
	fs.mkdirAll(path.dirname(pkgPath))
	fs.write(pkgPath, json.encode(portfile))
end

--- Runs `fn` with LDE_HOME pointed at `treeDir`, restoring the previous value.
---@param treeDir string
---@param fn fun()
local function withHome(treeDir, fn)
	const saved = env.var("LDE_HOME")
	env.set("LDE_HOME", treeDir)
	local ok, err = pcall(fn)
	env.set("LDE_HOME", saved)
	if not ok then error(err, 0) end
end

---@param relativeTo string
---@return lde.install.Context
local function fakeContext(relativeTo)
	return {
		relativeTo = relativeTo,
		stack = {},
		downloads = 0,
		builds = 0,
		dependencies = {},
		modulesDir = path.join(relativeTo, "modules"),
		enabledOptional = {},
		build = {
			addNode = function() end,
			finish = function() end,
		},
	}
end

--
-- depSourceKey
--

test.it("depSourceKey uses the effective git URL of the selected registry version", function()
	const treeDir = path.join(tmpBase, "tree-dep-source")
	writeRegistry(treeDir, {
		name = "dep-source-pkg",
		git = "https://example.com/main",
		branch = "main",
		versions = {
			["1.0.0"] = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			["2.0.0"] = {
				commit = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
				git = "https://example.com/fork",
			},
		},
	})

	withHome(treeDir, function()
		test.equal(nodeModel.depSourceKey("dep-source-pkg", { version = "1.0.0" }, treeDir),
			"git:https://example.com/main.git", "a bare commit inherits the portfile git")
		test.equal(nodeModel.depSourceKey("dep-source-pkg", { version = "2.0.0" }, treeDir),
			"git:https://example.com/fork.git", "the version object overrides the git URL")
		test.equal(nodeModel.depSourceKey("aliased", { name = "dep-source-pkg", version = "2.0.0" }, treeDir),
			"git:https://example.com/fork.git", "the alias resolves through depInfo.name")
	end)
end)

test.it("depSourceKey treats the same repo with and without .git as equal", function()
	const treeDir = path.join(tmpBase, "tree-dep-key")
	writeRegistry(treeDir, {
		name = "key-pkg",
		git = "https://example.com/repo.git",
		versions = { ["1.0.0"] = "cccccccccccccccccccccccccccccccccccccccc" },
	})

	withHome(treeDir, function()
		const registryKey = nodeModel.depSourceKey("key-pkg", { version = "1.0.0" }, treeDir)
		const gitKey = nodeModel.depSourceKey("key-pkg", { git = "https://example.com/repo" }, treeDir)
		test.equal(registryKey, gitKey)
	end)
end)

test.it("depSourceKey falls back to the version form when the portfile is missing", function()
	const treeDir = path.join(tmpBase, "tree-dep-missing")
	withHome(treeDir, function()
		test.equal(nodeModel.depSourceKey("ghost", { version = "1.0.0" }, treeDir), "registry:ghost@1.0.0")
	end)
end)

--
-- makeNode, registry branch
--

test.it("makeNode plans a registry dep from the version's git override", function()
	const treeDir = path.join(tmpBase, "tree-make-node")
	writeRegistry(treeDir, {
		name = "override-pkg",
		git = "https://example.com/main",
		branch = "main",
		versions = {
			["1.0.0"] = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			["2.0.0"] = {
				commit = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
				git = "https://example.com/fork",
				branch = "release",
			},
		},
	})

	withHome(treeDir, function()
		const node = nodeModel.makeNode("override-pkg", { version = "2.0.0" }, treeDir, fakeContext(treeDir))
		const gitPlan = assert(node.gitPlan)
		const clone = assert(gitPlan.clone)
		test.equal(node.kind, "git")
		test.equal(node.repoName, "override-pkg")
		test.equal(gitPlan.commit, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
		test.equal(gitPlan.url, "https://example.com/fork")
		test.equal(clone.repoUrl, "https://example.com/fork")
		test.equal(clone.branch, "release")
		-- The lockfile records the branch as the clone hint.
		test.equal(node.depInfo.branch, "release")
		test.equal(node.sourceKey, "git:https://example.com/fork.git")
	end)
end)

test.it("makeNode keeps the top-level source for a bare commit version", function()
	const treeDir = path.join(tmpBase, "tree-make-node-legacy")
	writeRegistry(treeDir, {
		name = "legacy-pkg",
		git = "https://example.com/main",
		branch = "stable",
		versions = { ["1.0.0"] = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
	})

	withHome(treeDir, function()
		const node = nodeModel.makeNode("legacy-pkg", { version = "1.0.0" }, treeDir, fakeContext(treeDir))
		const gitPlan = assert(node.gitPlan)
		const clone = assert(gitPlan.clone)
		test.equal(gitPlan.url, "https://example.com/main")
		test.equal(clone.branch, "stable")
		test.equal(node.sourceKey, "git:https://example.com/main.git")
	end)
end)
