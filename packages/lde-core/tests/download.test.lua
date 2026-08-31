-- Unit tests for lde-core.util.download's session seeding: partial leftover
-- files from interrupted runs must not be trusted as complete downloads, or
-- the next sync extracts garbage ("Failed to extract") instead of re-fetching.
local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")

local download = require("lde-core.util.download")

local tmpBase = path.join(env.tmpdir(), "lde-download-tests")
fs.rmdir(tmpBase)
fs.mkdirAll(tmpBase)

local archiveCache = path.join(tmpBase, "archives")
local destBase = path.join(tmpBase, "dest")

--- Fresh session against an empty archive cache. The batch is created (curl
--- is loaded) but nothing is transferred unless a test adds a real URL.
---@return string cacheDir
local function beginSession()
	-- Another lde-core test may have left a session open (an aborted install);
	-- the module-level session is a singleton, so clear it first.
	download.abort()
	fs.rmdir(archiveCache)
	fs.mkdirAll(archiveCache)
	fs.mkdirAll(destBase)
	download.begin({ archiveCache = archiveCache })
	return archiveCache
end

test.it("prefetch discards a partial leftover download instead of trusting it", function()
	beginSession()
	local dest = path.join(destBase, "leftover.archive")
	fs.write(dest, "partial bytes") -- an interrupted download left this behind

	local status = download.prefetch("https://example.com/x.tar.gz", dest)
	test.equal(status, "pending", "a partial leftover must not count as cached")
	-- batch:add reopens the destination with "wb", so the leftover is gone
	-- (truncated to an empty transfer output), not trusted as complete.
	test.equal(fs.stat(dest).size, 0, "the partial bytes must not survive as a cache hit")
	download.abort()
end)

test.it("background discards a partial leftover download instead of trusting it", function()
	beginSession()
	local dest = path.join(destBase, "leftover2.archive")
	fs.write(dest, "partial bytes")

	local status = download.background("https://example.com/y.tar.gz", dest)
	test.equal(status, "pending")
	test.equal(fs.stat(dest).size, 0, "the partial bytes must not survive as a cache hit")
	download.abort()
end)

test.it("prefetch trusts a leftover backed by the user-level archive cache", function()
	beginSession()
	-- A completed transfer is copied into the archive cache by resolveTransfer;
	-- a leftover with a matching copy there is a full download, not a partial.
	local name = "full.archive"
	fs.write(path.join(archiveCache, name), "complete bytes")
	local dest = path.join(destBase, name)
	fs.write(dest, "complete bytes")

	local status = download.prefetch("https://example.com/full", dest)
	test.equal(status, "done", "an archive-cache-backed leftover must count as cached")
	test.truthy(fs.exists(dest), "the file must be left in place")
	download.finish()
end)

test.it("prefetch reseeds a partial leftover from the user-level archive cache", function()
	beginSession()
	-- The leftover is a partial download, but the archive cache has the full
	-- copy: the partial bytes must be replaced, not trusted (or extraction
	-- would fail with "bad data" on every run).
	local name = "reseed.archive"
	fs.write(path.join(archiveCache, name), "complete bytes")
	local dest = path.join(destBase, name)
	fs.write(dest, "par")

	local status = download.prefetch("https://example.com/reseed", dest)
	test.equal(status, "done")
	test.equal(fs.read(dest), "complete bytes", "partial leftover must be replaced by the cached copy")
	download.finish()
end)

test.it("prefetch seeds destPath from the user-level archive cache", function()
	beginSession()
	local name = "seeded.archive"
	fs.write(path.join(archiveCache, name), "complete bytes")
	local dest = path.join(destBase, name)

	local status = download.prefetch("https://example.com/seeded", dest)
	test.equal(status, "done", "an archive-cache hit must skip the network")
	test.equal(fs.read(dest), "complete bytes")
	download.finish()
end)
