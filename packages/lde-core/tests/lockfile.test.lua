local test = require("lde-test")

local lde = require("lde-core")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")

local tmpBase = path.join(env.tmpdir(), "lde-lockfile-tests")

-- Clean up from any previous test run
fs.rmdir(tmpBase)

test.it("Lockfile.new creates a lockfile with version and dependencies", function()
	local lf = lde.Lockfile.new(path.join(tmpBase, "test-lock.json"), {
		foo = { path = "../foo" }
	})

	test.equal(lf:getVersion(), "1")
	test.equal(lf:getDependency("foo").path, "../foo")
end)

test.it("Lockfile.new with empty dependencies", function()
	local lf = lde.Lockfile.new(path.join(tmpBase, "empty-lock.json"), {})

	test.equal(lf:getVersion(), "1")
	local deps = lf:getDependencies()
	test.equal(test.count(deps), 0)
end)

test.it("Lockfile:save writes to disk and Lockfile.open reads it back", function()
	local dir = path.join(tmpBase, "roundtrip")
	fs.mkdir(tmpBase)
	fs.mkdir(dir)

	local lockPath = path.join(dir, "lde.lock")

	local lf = lde.Lockfile.new(lockPath, {
		alpha = { path = "../alpha" },
		beta = { git = "https://example.com/beta.git", commit = "abc123", branch = "main" }
	})

	lf:save()

	test.truthy(fs.exists(lockPath))

	local loaded = lde.Lockfile.open(lockPath) ---@cast loaded -nil
	test.equal(loaded:getVersion(), "1")
	local alpha = loaded:getDependency("alpha") ---@cast alpha table
	test.match(alpha, { path = "../alpha" })
	local beta = loaded:getDependency("beta") ---@cast beta table
	test.match(beta, {
		git = "https://example.com/beta.git",
		commit = "abc123",
		branch = "main"
	})
end)

test.it("Lockfile.open returns nil for a missing file", function()
	local result = lde.Lockfile.open(path.join(tmpBase, "does-not-exist.json"))
	test.falsy(result)
end)

test.it("Lockfile:getDependency returns nil for unknown dependency", function()
	local lf = lde.Lockfile.new(path.join(tmpBase, "x.json"), {
		known = { path = "../known" }
	})

	test.falsy(lf:getDependency("unknown"))
end)

test.it("Lockfile:save produces valid JSON", function()
	local dir = path.join(tmpBase, "json-check")
	fs.mkdir(tmpBase)
	fs.mkdir(dir)

	local lockPath = path.join(dir, "lde.lock")

	local lf = lde.Lockfile.new(lockPath, {
		mylib = { path = "../mylib" }
	})

	lf:save()

	local content = fs.read(lockPath) ---@cast content -nil
	local decoded = json.decode(content) ---@cast decoded table
	test.match(decoded, { version = "1", dependencies = { mylib = { path = "../mylib" } } })
end)

test.it("Lockfile.manifestHash is stable and tracks the dependency declarations", function()
	local config = {
		dependencies = {
			a = { git = "https://example.com/a.git" },
			b = { version = "1.0.0" }
		}
	}

	local h1 = lde.Lockfile.manifestHash(config)
	test.equal(h1, lde.Lockfile.manifestHash(config))

	-- Key order in a hand-built table must not matter (json.encode sorts).
	local reordered = {
		dependencies = {
			b = { version = "1.0.0" },
			a = { git = "https://example.com/a.git" }
		}
	}
	test.equal(h1, lde.Lockfile.manifestHash(reordered))

	-- Changing a declaration must change the hash.
	config.dependencies.b.version = "2.0.0"
	test.falsy(h1 == lde.Lockfile.manifestHash(config))

	-- devDependencies and features are part of the hash too.
	config.devDependencies = { dev = { path = "../dev" } }
	test.falsy(h1 == lde.Lockfile.manifestHash(config))
	config.devDependencies = nil
	config.features = { linux = { "winapi" } }
	test.falsy(h1 == lde.Lockfile.manifestHash(config))
end)

test.it("Lockfile:isStale flags missing and mismatched manifest hashes", function()
	local lockPath = path.join(tmpBase, "stale-check.json")
	local config = { dependencies = { foo = { version = "1.0.0" } } }

	-- Lockfiles written before manifest hashing existed are stale.
	local lf = lde.Lockfile.new(lockPath, {})
	test.truthy(lf:isStale(config))

	-- A matching hash means the pins are trustworthy.
	lf:setManifestHash(lde.Lockfile.manifestHash(config))
	test.falsy(lf:isStale(config))

	-- Editing the manifest invalidates the lockfile again.
	config.dependencies.foo.version = "2.0.0"
	test.truthy(lf:isStale(config))
end)
