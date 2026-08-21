-- Unit tests for lde-core.util's luarocks URL cache and its offline src-rock
-- fallback. Both are hermetic: HOME is redirected to a throwaway dir so the
-- real ~/.lde url cache and manifest are never read or written.
local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")
local process = require("process")

local tmpBase = path.join(env.tmpdir(), "lde-util-tests")
fs.rmdir(tmpBase)
fs.mkdirAll(tmpBase)

local realHome = env.var("HOME") or env.var("USERPROFILE")
test.truthy(env.set("HOME", tmpBase), "could not redirect HOME for test isolation")
test.afterAll(function()
	env.set("HOME", realHome)
end)

local lde = require("lde-core")

local userDir = path.join(tmpBase, ".lde")
fs.mkdirAll(userDir)

--
-- The URL cache must survive a manifest refresh
--

test.it("URL cache entries survive a manifest refresh and a later resolution", function()
	-- Pre-existing entries (e.g. cerulean, busted) written before the manifest
	-- was last refreshed — the condition that used to drop the whole persisted
	-- cache on the next online resolution.
	local cachePath = path.join(userDir, "luarocks-url-cache-5.1.json")
	fs.write(cachePath, json.encode({
		alpha = { url = "https://luarocks.org/alpha-1.0.0-1.src.rock", arch = "src" },
		beta  = { url = "https://luarocks.org/beta-2.0.0-1.src.rock", arch = "src" },
	}))
	local touchCode = process.exec("touch", { "-t", "202001010000", cachePath })
	test.truthy(touchCode == 0, "touch url cache to an old mtime failed: " .. tostring(touchCode))

	-- A freshly refreshed manifest (mtime = now), the state `lde search` or
	-- `lde outdated` leaves behind.
	fs.write(path.join(userDir, "luarocks-manifest.raw"),
		'repository = {\n  gamma = {\n    ["1.0.0-1"] = {\n      arch = "src"\n    }\n  }\n}\n')

	local url, arch, err = lde.util.resolveLuarocksSource("gamma", nil, false)
	test.truthy(url, "unversioned online resolution failed: " .. tostring(err))
	test.equal(arch, "src")
	test.includes(url or "", "gamma-1.0.0-1.src.rock")

	-- The persisted cache must still contain the pre-existing entries plus the
	-- newly resolved one. The regression this guards against rewrote the file
	-- with only the package being resolved right now, breaking every other
	-- cached rocks tool on the next offline run.
	local persisted = json.decode(assert(fs.read(cachePath))) ---@cast persisted table<string, any>
	test.truthy(persisted.alpha, "stale url cache entries must survive a manifest refresh")
	test.truthy(persisted.beta, "stale url cache entries must survive a manifest refresh")
	test.truthy(persisted.gamma, "newly resolved entry must be persisted")
end)

--
-- The offline fallback: a materialized src rock rescues a lost URL cache entry
--

test.it("offline resolution falls back to a materialized src rock when the URL cache misses", function()
	-- A src rock that was installed earlier and is still materialized in the
	-- tar cache (dirs are named by the sanitized download URL).
	local srcRockDir = path.join(userDir, "tar", "https___fake_org_zqcachetool-1_0_0-1_src_rock")
	fs.mkdirAll(path.join(srcRockDir, "zqcachetool-1.0.0", "src"))
	fs.write(path.join(srcRockDir, "zqcachetool-1.0.0", "src", "init.lua"), 'print("hi")')
	fs.write(path.join(srcRockDir, "zqcachetool-1.0.0-1.rockspec"), [[
package = "zqcachetool"
version = "1.0.0-1"
source = { url = "https://fake.org/zqcachetool-1.0.0.tar.gz" }
build = { type = "builtin", modules = { zqcachetool = "src/init.lua" } }
]])

	-- zqcachetool is not in the url cache (alpha/beta/gamma only), so the
	-- offline lookup must recover it from the tar cache instead of erroring.
	local pkg, lockEntry, err = lde.util.openLuarocksPackage("zqcachetool", nil, true)
	test.truthy(pkg, "offline open of a materialized src rock failed: " .. tostring(err)) ---@cast pkg -nil
	test.equal(pkg:getName(), "zqcachetool")
	test.truthy(lockEntry, "offline fallback must return a lock entry")
end)

--
-- The manifest package-name index (search fast path)
--

test.it("getManifestNames extracts quoted and bare keys and caches them", function()
	fs.write(path.join(userDir, "luarocks-manifest.raw"), [[
repository = {
  ["alpha-pkg"] = {
    ["1.0.0-1"] = { arch = "src" }
  },
  beta = {
    ["2.0.0-1"] = { arch = "rockspec" }
  }
}
]])

	local names = lde.util.getManifestNames()
	test.equal(#names, 2)
	test.includes(names[1] .. "," .. names[2], "alpha-pkg")
	test.includes(names[1] .. "," .. names[2], "beta")

	-- The derived index is persisted and served on the next call.
	local cachePath = path.join(userDir, "luarocks-names-5.1.json")
	test.truthy(fs.exists(cachePath), "the name index must be written")
	local cached = lde.util.getManifestNames()
	test.equal(#cached, 2)

	-- A newer manifest rebuilds the index.
	fs.write(path.join(userDir, "luarocks-manifest.raw"), "repository = {\n  gamma = {\n    [\"3.0.0-1\"] = { arch = \"src\" }\n  }\n}\n")
	local rebuilt = lde.util.getManifestNames()
	test.equal(#rebuilt, 1)
	test.equal(rebuilt[1], "gamma")
end)
