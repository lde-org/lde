local test = require("lpm-test")

local lpm = require("lpm-core")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")

local tmpBase = path.join(env.tmpdir(), "lpm-lockfile-tests")

-- Clean up from any previous test run
fs.rmdir(tmpBase)

test.it("Lockfile.new creates a lockfile with version and dependencies", function()
	local lf = lpm.Lockfile.new(path.join(tmpBase, "test-lock.json"), {
		foo = { path = "../foo" }
	})

	test.equal(lf:getVersion(), "1")
	test.equal(lf:getDependency("foo").path, "../foo")
end)

test.it("Lockfile.new with empty dependencies", function()
	local lf = lpm.Lockfile.new(path.join(tmpBase, "empty-lock.json"), {})

	test.equal(lf:getVersion(), "1")
	local deps = lf:getDependencies()
	test.equal(test.count(deps), 0)
end)

test.it("Lockfile:save writes to disk and Lockfile.open reads it back", function()
	local dir = path.join(tmpBase, "roundtrip")
	fs.mkdir(tmpBase)
	fs.mkdir(dir)

	local lockPath = path.join(dir, "lpm-lock.json")

	local lf = lpm.Lockfile.new(lockPath, {
		alpha = { path = "../alpha" },
		beta = { git = "https://example.com/beta.git", commit = "abc123", branch = "main" }
	})

	lf:save()

	test.truthy(fs.exists(lockPath))

	local loaded = lpm.Lockfile.open(lockPath)
	test.equal(loaded:getVersion(), "1")
	test.equal(loaded:getDependency("alpha").path, "../alpha")
	test.equal(loaded:getDependency("beta").git, "https://example.com/beta.git")
	test.equal(loaded:getDependency("beta").commit, "abc123")
	test.equal(loaded:getDependency("beta").branch, "main")
end)

test.it("Lockfile.open returns nil for a missing file", function()
	local result = lpm.Lockfile.open(path.join(tmpBase, "does-not-exist.json"))
	test.falsy(result)
end)

test.it("Lockfile:getDependency returns nil for unknown dependency", function()
	local lf = lpm.Lockfile.new(path.join(tmpBase, "x.json"), {
		known = { path = "../known" }
	})

	test.falsy(lf:getDependency("unknown"))
end)

test.it("Lockfile:save produces valid JSON", function()
	local dir = path.join(tmpBase, "json-check")
	fs.mkdir(tmpBase)
	fs.mkdir(dir)

	local lockPath = path.join(dir, "lpm-lock.json")

	local lf = lpm.Lockfile.new(lockPath, {
		mylib = { path = "../mylib" }
	})

	lf:save()

	local content = fs.read(lockPath)
	local decoded = json.decode(content)
	test.equal(decoded.version, "1")
	test.equal(decoded.dependencies.mylib.path, "../mylib")
end)
