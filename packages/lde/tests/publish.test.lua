const test = require("lde-test")
const json = require("json")

const portfile = require("lde.github.portfile")
const publish = require("lde.github.publish")

local COMMIT = "abcdef0123456789abcdef0123456789abcdef01"
local OLD_COMMIT = "1234567890abcdef1234567890abcdef12345678"

---@param overrides table?
local function baseInput(overrides)
	local input = {
		name = "example",
		version = "1.0.0",
		commit = COMMIT,
		git = "https://github.com/owner/example.git",
		branch = "main",
		description = "An example",
		authors = { "Example <example@example.com>" },
		tags = { "tool", "cli" },
	}
	for key, value in pairs(overrides or {}) do input[key] = value end
	return input
end

test.it("normalizes tags by lowercasing, deduplicating and sorting", function()
	const tags, err = portfile.normalizeTags({ "CLI", "tool", "cli", " tool " })
	test.truthy(tags, err)
	test.deepEqual(tags, { "cli", "tool" })
end)

test.it("rejects malformed tags and more than ten tags", function()
	local invalid, invalidErr = portfile.normalizeTags({ "1bad" })
	test.falsy(invalid)
	test.includes(invalidErr, "Invalid tag")

	local many = {}
	for i = 1, 11 do many[i] = "tag" .. i end
	local tooMany, tooManyErr = portfile.normalizeTags(many)
	test.falsy(tooMany)
	test.includes(tooManyErr, "At most 10 tags")
end)

test.it("builds a first-publish portfile with ordered fields", function()
	local result = portfile.merge(nil, baseInput())
	test.equal(result.kind, "new")
	test.truthy(result.portfile)

	local built = result.portfile
	test.equal(built.name, "example")
	test.equal(built.versions["1.0.0"], COMMIT)
	test.deepEqual(built.tags, { "cli", "tool" })

	local encoded = json.encode(built)
	test.includes(encoded, '\n\t"name": "example"')
	test.includes(encoded, '\n\t"description": "An example"')
	test.includes(encoded, '\n\t"git": "https://github.com/owner/example.git"')
	test.includes(encoded, '\n\t"branch": "main"')
	test.includes(encoded, '\n\t"versions": {')

	local order = { "name", "description", "license", "authors", "tags", "git", "branch", "versions" }
	local last = 0
	for _, field in ipairs(order) do
		local position = encoded:find('"' .. field .. '"', 1, true)
		if position then
			test.truthy(position > last, field .. " should keep portfile field order")
			last = position
		end
	end
end)

test.it("leaves an unchanged version alone", function()
	local existing = {
		name = "example",
		git = "https://github.com/owner/example.git",
		branch = "main",
		versions = { ["1.0.0"] = COMMIT },
	}
	local result = portfile.merge(existing, baseInput())
	test.equal(result.kind, "unchanged")
	test.falsy(result.portfile)
end)

test.it("refuses to move an already published version", function()
	local existing = {
		name = "example",
		git = "https://github.com/owner/example.git",
		branch = "main",
		versions = { ["1.0.0"] = OLD_COMMIT },
	}
	local result = portfile.merge(existing, baseInput())
	test.equal(result.kind, "conflict")
	test.equal(result.err,
		"Version 1.0.0 is already published with commit 1234567; bump the version instead.")
end)

test.it("preserves existing versions and overrides the source per version", function()
	local existing = {
		name = "example",
		git = "https://github.com/old/example.git",
		branch = "main",
		versions = {
			["0.9.0"] = OLD_COMMIT,
			["0.8.0"] = { commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", git = "https://github.com/pinned/repo.git" },
		},
	}

	local result = portfile.merge(existing, baseInput({
		version = "1.0.0",
		git = "https://github.com/new/example.git",
		branch = "release",
	}))
	test.equal(result.kind, "new")

	local built = result.portfile
	test.equal(built.git, "https://github.com/old/example.git")
	test.equal(built.branch, "main")
	test.equal(built.versions["0.9.0"], OLD_COMMIT)
	test.equal(built.versions["0.8.0"].git, "https://github.com/pinned/repo.git")

	local entry = built.versions["1.0.0"]
	test.equal(entry.commit, COMMIT)
	test.equal(entry.git, "https://github.com/new/example.git")
	test.equal(entry.branch, "release")
end)

test.it("stores a bare commit when the version inherits the top-level source", function()
	local existing = {
		name = "example",
		git = "https://github.com/owner/example.git",
		branch = "main",
		versions = { ["0.9.0"] = OLD_COMMIT },
	}
	local result = portfile.merge(existing, baseInput())
	test.equal(result.kind, "new")
	test.equal(result.portfile.versions["1.0.0"], COMMIT)
end)

test.it("ignores a .git suffix when deciding a version override", function()
	local existing = {
		name = "example",
		git = "https://github.com/owner/example.git",
		branch = "main",
		versions = { ["0.9.0"] = OLD_COMMIT },
	}
	local result = portfile.merge(existing, baseInput({ git = "https://github.com/owner/example" }))
	test.equal(result.kind, "new")
	test.equal(result.portfile.versions["1.0.0"], COMMIT)
end)

test.it("preserves tags when the manifest has none and replaces them otherwise", function()
	local existing = {
		name = "example",
		git = "https://github.com/owner/example.git",
		branch = "main",
		tags = { "old", "tags" },
		versions = { ["0.9.0"] = OLD_COMMIT },
	}

	local preservedInput = baseInput()
	preservedInput.tags = nil
	local preserved = portfile.merge(existing, preservedInput)
	test.deepEqual(preserved.portfile.tags, { "old", "tags" })

	local replaced = portfile.merge(existing, baseInput({ tags = { "new" } }))
	test.deepEqual(replaced.portfile.tags, { "new" })
end)

test.it("sorts versions in semver order", function()
	local existing = {
		name = "example",
		git = "https://github.com/owner/example.git",
		branch = "main",
		versions = {
			["1.10.0"] = OLD_COMMIT,
			["1.2.0"] = OLD_COMMIT,
			["0.9.0"] = OLD_COMMIT,
		},
	}
	local result = portfile.merge(existing, baseInput({ version = "2.0.0" }))
	local encoded = json.encode(result.portfile)
	local first = encoded:find('"0.9.0"', 1, true)
	local second = encoded:find('"1.2.0"', 1, true)
	local third = encoded:find('"1.10.0"', 1, true)
	local fourth = encoded:find('"2.0.0"', 1, true)
	test.truthy(first < second)
	test.truthy(second < third)
	test.truthy(third < fourth)
end)

test.it("describes a first publish", function()
	local check = publish.preflight({
		name = "example",
		existing = nil,
		authority = {},
		userId = 1,
	})
	test.equal(check.message,
		"First publish of example. A moderator must approve this pull request before it goes live.")
	test.falsy(check.blocked)
end)

test.it("recognizes a package owner", function()
	local check = publish.preflight({
		name = "example",
		existing = { name = "example" },
		authority = { top = { example = { 42 } } },
		userId = 42,
	})
	test.equal(check.kind, "owner")
	test.equal(check.message, "You own example. This update will be auto-approved and merged.")
	test.falsy(check.blocked)
end)

test.it("recognizes a repository admin", function()
	local check = publish.preflight({
		name = "example",
		existing = { name = "example" },
		authority = { top = { example = { 1 } } },
		userId = 42,
		isAdmin = true,
	})
	test.equal(check.kind, "admin")
	test.equal(check.message, "Repository maintainer. This update will be auto-approved and merged.")
	test.falsy(check.blocked)
end)

test.it("blocks a non-owner", function()
	local check = publish.preflight({
		name = "example",
		existing = { name = "example" },
		authority = { top = { example = { 1 } } },
		userId = 42,
	})
	test.truthy(check.blocked)
	test.equal(check.message, "You do not own example; only its owner or a repository admin can update it.")
end)

test.it("checks namespace ownership on a new namespaced package", function()
	local blocked = publish.preflight({
		name = "ns/example",
		existing = nil,
		authority = { namespaces = { ns = { 1 } } },
		userId = 42,
	})
	test.truthy(blocked.blocked)

	local unclaimed = publish.preflight({
		name = "ns/example",
		existing = nil,
		authority = { namespaces = {} },
		userId = 42,
	})
	test.falsy(unclaimed.blocked)
	test.equal(unclaimed.note,
		"Namespace ns is not claimed yet; a moderator will create it when this package is approved.")
end)

test.it("builds a safe branch name and a marked pull request body", function()
	test.equal(publish.branchName("ns/example", "1.0.0", COMMIT), "publish/ns-example/1.0.0-abcdef0")

	local body = publish.prBody({
		name = "example",
		version = "1.0.0",
		commit = COMMIT,
		git = "https://github.com/owner/example.git",
		branch = "main",
		login = "octocat",
		id = 123,
		tags = { "cli", "tool" },
	})
	test.includes(body, "<!-- lde-publish -->")
	test.includes(body, "- Package: `example`")
	test.includes(body, "- Version: `1.0.0`")
	test.includes(body, "- Commit: `" .. COMMIT .. "`")
	test.includes(body, "- Source: `https://github.com/owner/example.git`")
	test.includes(body, "@octocat")
	test.includes(body, "123")
	test.includes(body, "cli, tool")
end)

test.it("derives owner and repository from registry URL forms", function()
	local owner, repository = publish.parseRepo("https://github.com/lde-org/registry")
	test.equal(owner, "lde-org")
	test.equal(repository, "registry")

	owner, repository = publish.parseRepo("git@github.com:lde-org/registry.git")
	test.equal(owner, "lde-org")
	test.equal(repository, "registry")

	owner, repository = publish.parseRepo("ssh://git@github.com/lde-org/registry.git")
	test.equal(owner, "lde-org")
	test.equal(repository, "registry")

	local badOwner, _, badErr = publish.parseRepo("https://gitlab.com/lde-org/registry")
	test.falsy(badOwner)
	test.includes(badErr, "not a GitHub repository")
end)

test.it("dry-run prints the preflight, portfile and pull request title", function()
	local emitted = {}
	local api = {
		request = function(method, requestPath)
			if requestPath == "/repos/lde-org/registry" then
				return { default_branch = "master", permissions = { admin = false } }, 200, nil
			end
			return nil, 500, "unexpected request"
		end,
		fetchRaw = function()
			return nil, 404, nil
		end,
		setToken = function() end,
	}
	local auth = {
		load = function() return nil, nil end,
	}

	local result, err = publish.run({
		name = "example",
		version = "1.0.0",
		commit = COMMIT,
		gitUrl = "git@github.com:owner/example.git",
		branch = "main",
		config = { name = "example", version = "1.0.0", description = "An example" },
		registryUrl = "https://github.com/lde-org/registry",
		dryRun = true,
		api = api,
		auth = auth,
		emit = function(message) emitted[#emitted + 1] = message end,
	})

	test.truthy(result, err)
	test.equal(result.dryRun, true)
	test.equal(result.portfile.git, "https://github.com/owner/example.git")

	local output = table.concat(emitted, "\n")
	test.includes(output, "First publish of example.")
	test.includes(output, '"name": "example"')
	test.includes(output, "Pull request: Publish example@1.0.0")
end)

test.it("forks the registry when the user cannot push upstream", function()
	local requests = {}
	local api = {
		request = function(method, requestPath, body)
			requests[#requests + 1] = { method = method, path = requestPath, body = body }
			if requestPath == "/repos/lde-org/registry" then
				return { default_branch = "master", permissions = { push = false } }, 200, nil
			elseif requestPath == "/repos/lde-org/registry/forks" then
				return { full_name = "user/registry", owner = { login = "user" } }, 202, nil
			elseif requestPath == "/repos/user/registry/merge-upstream" then
				return { message = "up to date" }, 204, nil
			elseif requestPath == "/repos/user/registry/git/ref/heads/master" then
				return { object = { sha = "basecommit" } }, 200, nil
			elseif requestPath == "/repos/user/registry/git/blobs" then
				return { sha = "blobsha" }, 201, nil
			elseif requestPath == "/repos/user/registry/git/commits/basecommit" then
				return { tree = { sha = "treesha" } }, 200, nil
			elseif requestPath == "/repos/user/registry/git/trees" then
				return { sha = "newtree" }, 201, nil
			elseif requestPath == "/repos/user/registry/git/commits" then
				return { sha = "newcommit" }, 201, nil
			elseif requestPath == "/repos/user/registry/git/refs" then
				return { ref = body.ref }, 201, nil
			elseif requestPath == "/repos/lde-org/registry/pulls" then
				return { html_url = "https://github.com/lde-org/registry/pull/1", number = 1 }, 201, nil
			end
			return nil, 500, "unexpected request " .. requestPath
		end,
		fetchRaw = function(url)
			if url:find("/packages/example.json", 1, true) then
				return nil, 404, nil
			end
			return '{"top":{},"namespaces":{}}', 200, nil
		end,
		setToken = function() end,
	}
	local session = { accessToken = "token", id = 42, login = "user" }
	local auth = {
		ensureValid = function() return session end,
		refresh = function() return session end,
	}

	local result, err = publish.run({
		name = "example",
		version = "1.0.0",
		commit = COMMIT,
		gitUrl = "git@github.com:owner/example.git",
		branch = "main",
		config = { name = "example", version = "1.0.0", description = "An example" },
		registryUrl = "https://github.com/lde-org/registry",
		api = api,
		auth = auth,
		sleep = function() end,
		emit = function() end,
	})

	test.truthy(result, err)
	test.equal(result.pullRequest.number, 1)

	local pulled = false
	local usedFork = false
	for _, request in ipairs(requests) do
		if request.path == "/repos/lde-org/registry/pulls" then
			pulled = true
			test.equal(request.body.head, "user:publish/example/1.0.0-abcdef0")
		end
		if request.path:find("/repos/user/registry/git/", 1, true) then usedFork = true end
	end
	test.truthy(pulled)
	test.truthy(usedFork)
end)

test.it("builds an archive-only portfile with a SHA-256 pin", function()
	local hash = string.rep("a", 64)
	local result = portfile.merge(nil, {
		name = "tarball",
		version = "1.0.0",
		archive = "https://example.com/tarball-1.0.0.tar.gz",
		sha256 = hash,
		size = 1234,
		description = "A tarball package",
	})
	test.equal(result.kind, "new")
	test.falsy(result.portfile.git)
	test.equal(result.portfile.versions["1.0.0"].archive, "https://example.com/tarball-1.0.0.tar.gz")
	test.equal(result.portfile.versions["1.0.0"].sha256, hash)
	test.equal(result.portfile.versions["1.0.0"].size, 1234)
end)

test.it("keeps an archive version unchanged only for the same hash", function()
	local hash = string.rep("a", 64)
	local existing = {
		name = "tarball",
		versions = {
			["1.0.0"] = { archive = "https://example.com/tarball.tar.gz", sha256 = hash },
		},
	}
	local unchanged = portfile.merge(existing, {
		name = "tarball",
		version = "1.0.0",
		archive = "https://example.com/tarball.tar.gz",
		sha256 = hash,
	})
	test.equal(unchanged.kind, "unchanged")

	local changed = portfile.merge(existing, {
		name = "tarball",
		version = "1.0.0",
		archive = "https://example.com/tarball.tar.gz",
		sha256 = string.rep("b", 64),
	})
	test.equal(changed.kind, "conflict")
	test.includes(changed.err, "different archive or SHA-256")
end)

test.it("dry-runs an archive publish without a git repository", function()
	local emitted = {}
	local api = {
		request = function(method, requestPath)
			if requestPath == "/repos/lde-org/registry" then
				return { default_branch = "master", permissions = { push = false } }, 200, nil
			end
			return nil, 500, "unexpected request"
		end,
		fetchRaw = function() return nil, 404, nil end,
		setToken = function() end,
	}
	local auth = { load = function() return nil, nil end }
	local hash = string.rep("a", 64)

	local result, err = publish.run({
		name = "tarball",
		version = "1.0.0",
		archive = "https://example.com/tarball.tar.gz",
		sha256 = hash,
		size = 123,
		config = { name = "tarball", version = "1.0.0", description = "Tarball" },
		registryUrl = "https://github.com/lde-org/registry",
		dryRun = true,
		api = api,
		auth = auth,
		emit = function(message) emitted[#emitted + 1] = message end,
	})

	test.truthy(result, err)
	test.equal(result.dryRun, true)
	test.falsy(result.portfile.git)
	test.equal(result.portfile.versions["1.0.0"].sha256, hash)

	local output = table.concat(emitted, "\n")
	test.includes(output, '"archive": "https://example.com/tarball.tar.gz"')
	test.includes(output, '"sha256": "' .. hash .. '"')
	test.includes(output, "Pull request: Publish tarball@1.0.0")
end)

test.it("publishes a git version with its archive SHA-256", function()
	local hash = string.rep("c", 64)
	local result = portfile.merge(nil, {
		name = "gitpkg",
		version = "1.0.0",
		commit = COMMIT,
		git = "https://github.com/owner/example.git",
		branch = "main",
		sha256 = hash,
	})
	test.equal(result.kind, "new")
	local entry = result.portfile.versions["1.0.0"]
	test.equal(entry.commit, COMMIT)
	test.equal(entry.sha256, hash)
	test.equal(entry.git, nil)
	test.equal(entry.branch, nil)
end)

test.it("stores only the fields that differ from the top-level source", function()
	local existing = {
		name = "example",
		git = "https://github.com/owner/example.git",
		branch = "main",
		versions = { ["0.9.0"] = OLD_COMMIT },
	}

	local branchOnly = portfile.merge(existing, baseInput({
		version = "1.0.0",
		git = "https://github.com/owner/example.git",
		branch = "release",
	}))
	test.equal(branchOnly.portfile.versions["1.0.0"].git, nil)
	test.equal(branchOnly.portfile.versions["1.0.0"].branch, "release")

	local gitOnly = portfile.merge(existing, baseInput({
		version = "1.1.0",
		git = "https://github.com/new/example.git",
		branch = "main",
	}))
	test.equal(gitOnly.portfile.versions["1.1.0"].git, "https://github.com/new/example.git")
	test.equal(gitOnly.portfile.versions["1.1.0"].branch, nil)
end)

test.it("preserves the revoked list when publishing a new version", function()
	local existing = {
		name = "example",
		git = "https://github.com/owner/example.git",
		branch = "main",
		versions = { ["0.9.0"] = OLD_COMMIT },
		revoked = { "0.9.0" },
	}
	local result = portfile.merge(existing, baseInput({ version = "1.0.0" }))
	test.deepEqual(result.portfile.revoked, { "0.9.0" })
end)
