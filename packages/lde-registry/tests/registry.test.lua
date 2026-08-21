-- Registry unit tests. Every dependency is injected through the constructor,
-- so these tests run with in-memory fakes: no network, no real ~/.lde writes.
local test = require("lde-test")

local Registry = require("lde-registry")

local fs = require("fs")
local path = require("path")
local semver = require("semver")

local tmpBase = os.tmpname() .. ".d"
fs.rmdir(tmpBase)
fs.mkdirAll(tmpBase)

--- Builds a fake fs table backed by an in-memory table of path -> content.
---@param files table<string, string>?
---@return { read: fun(p: string): string?, exists: fun(p: string): boolean, mkdir: fun(p: string): boolean }
local function fakeFs(files)
	files = files or {}
	return {
		read = function(p)
			return files[p] or files[p:gsub("/", path.separator)] or nil
		end,
		exists = function(p)
			local key = files[p] ~= nil and p or p:gsub("/", path.separator)
			return files[key] ~= nil
		end,
		mkdir = function() return true end,
	}
end

---@param files table<string, string>?
---@return lde.Registry
local function newRegistry(files)
	return Registry.new({
		dirFn = function() return "/fake/registry" end,
		url = "https://example.com/registry.git",
		fs = fakeFs(files),
		path = path,
		semver = semver,
		git = function()
			return {
				clone = function() return { updateSubmodules = function() end }, nil end,
				open = function() return { pull = function() end } end,
			}
		end,
	})
end

--
-- validateName
--

test.it("validateName accepts flat and namespaced names", function()
	local registry = newRegistry()
	test.falsy(registry:validateName("foo"))
	test.falsy(registry:validateName("nsp/foo"))
	test.falsy(registry:validateName("foo-bar_1"))
end)

test.it("validateName rejects empty, invalid, and over-long names", function()
	local registry = newRegistry()
	test.truthy(registry:validateName(""))
	test.truthy(registry:validateName("Foo"))
	test.truthy(registry:validateName("foo..bar"))
	test.truthy(registry:validateName("/foo"))
	test.truthy(registry:validateName("foo/"))
	test.truthy(registry:validateName("a/b/c"))
	test.truthy(registry:validateName("ab/foo"))  -- namespace too short
	test.truthy(registry:validateName(string.rep("a", 129)))
end)

--
-- lookup
--

test.it("lookup reads a flat portfile", function()
	local registry = newRegistry({
		["/fake/registry/packages/foo.json"] = '{"name":"foo","git":"https://x/y.git","versions":{"1.0.0":"abc"}}',
	})
	local portfile, err = registry:lookup("foo")
	test.falsy(err)
	test.truthy(portfile, "portfile must be returned") ---@cast portfile lde.Portfile
	test.equal(portfile.name, "foo")
	test.equal(portfile.versions["1.0.0"], "abc")
end)

test.it("lookup reads a namespaced portfile", function()
	local registry = newRegistry({
		["/fake/registry/packages/nsp/foo.json"] = '{"name":"nsp/foo","git":"https://x/y.git","versions":{"1.0.0":"abc"}}',
	})
	local portfile, err = registry:lookup("nsp/foo")
	test.falsy(err)
	test.truthy(portfile, "portfile must be returned") ---@cast portfile lde.Portfile
	test.equal(portfile.name, "nsp/foo")
end)

test.it("lookup returns an error for missing packages", function()
	local registry = newRegistry()
	local portfile, err = registry:lookup("missing")
	test.falsy(portfile)
	test.truthy(err and err:find("not found", 1, true))
end)

test.it("lookup rejects invalid names before touching the fs", function()
	local registry = newRegistry()
	local portfile, err = registry:lookup("Bad.Name")
	test.falsy(portfile)
	test.truthy(err and err:find("Invalid package name", 1, true))
end)

test.it("lookup returns an error for malformed portfile JSON", function()
	local registry = newRegistry({
		["/fake/registry/packages/broken.json"] = "{not json",
	})
	local portfile, err = registry:lookup("broken")
	test.falsy(portfile)
	test.truthy(err and err:find("Invalid portfile", 1, true))
end)

--
-- resolveVersion
--

test.it("resolveVersion returns the exact requested version", function()
	local registry = newRegistry()
	local version, commit = registry:resolveVersion({ name = "foo", git = "https://x/y.git", versions = { ["1.0.0"] = "abc" } }, "1.0.0")
	test.equal(version, "1.0.0")
	test.equal(commit, "abc")
end)

test.it("resolveVersion picks the highest semver when version is nil", function()
	local registry = newRegistry()
	local portfile = { name = "foo", git = "https://x/y.git", versions = { ["1.0.0"] = "abc", ["2.1.0"] = "def", ["1.9.9"] = "ghi" } }
	local version, commit = registry:resolveVersion(portfile, nil)
	test.equal(version, "2.1.0")
	test.equal(commit, "def")
end)

test.it("resolveVersion raises for an unknown version", function()
	local registry = newRegistry()
	test.errors(function()
		registry:resolveVersion({ name = "foo", git = "https://x/y.git", versions = { ["1.0.0"] = "abc" } }, "9.9.9")
	end, "Version '9.9.9' of 'foo' not found in lde registry")
end)

test.it("resolveVersion raises when a portfile has no versions", function()
	local registry = newRegistry()
	test.errors(function()
		registry:resolveVersion({ name = "foo", git = "https://x/y.git" }, nil)
	end, "Package 'foo' has no versions in registry")
end)

--
-- sync
--

test.it("sync clones when the registry dir is missing", function()
	local clones, opens = 0, 0
	local registry = Registry.new({
		dirFn = function() return "/fake/registry" end,
		fs = { read = function() return nil end, exists = function() return false end },
		path = path,
		semver = semver,
		git = function()
			return {
				clone = function()
					clones = clones + 1
					return { updateSubmodules = function() end }, nil
				end,
				open = function()
					opens = opens + 1
					return { pull = function() end }
				end,
			}
		end,
	})
	registry:sync()
	registry:sync() -- second call must not clone again
	test.equal(clones, 1)
	test.equal(opens, 0)
end)

test.it("sync pulls when the registry dir exists", function()
	local clones, opens = 0, 0
	local registry = Registry.new({
		dirFn = function() return "/fake/registry" end,
		fs = { read = function() return nil end, exists = function() return true end },
		path = path,
		semver = semver,
		git = function()
			return {
				clone = function()
					clones = clones + 1
					return { updateSubmodules = function() end }, nil
				end,
				open = function()
					opens = opens + 1
					return { pull = function() end }
				end,
			}
		end,
	})
	registry:sync()
	test.equal(clones, 0)
	test.equal(opens, 1)
end)

test.it("sync raises when the clone fails", function()
	local raised
	local registry = Registry.new({
		dirFn = function() return "/fake/registry" end,
		fs = { read = function() return nil end, exists = function() return false end },
		path = path,
		semver = semver,
		raise = function(msg) raised = msg; error(msg, 0) end,
		git = function()
			return { clone = function() return nil, "network down" end }
		end,
	})
	local ok, err = pcall(function() registry:sync() end)
	test.falsy(ok)
	test.truthy(raised and raised:find("Failed to clone lde registry", 1, true))
end)

test.it("sync is a no-op without a git provider", function()
	local registry = Registry.new({
		dirFn = function() return "/fake/registry" end,
		fs = { read = function() return nil end, exists = function() return false end },
		path = path,
		semver = semver,
	})
	registry:sync() -- must not raise
	test.truthy(true)
end)
