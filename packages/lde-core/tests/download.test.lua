-- Unit tests for lde-core.util.download's session seeding: partial leftover
-- files from interrupted runs must not be trusted as complete downloads, or
-- the next sync extracts garbage ("Failed to extract") instead of re-fetching.
const test = require("lde-test")

const fs = require("fs")
const env = require("env")
const path = require("path")

local download = require("lde-core.util.download")

local tmpBase = path.join(env.tmpdir(), "lde-download-tests")
fs.rmdir(tmpBase)
fs.mkdirAll(tmpBase)

local archiveCache = path.join(tmpBase, "archives")
local destBase = path.join(tmpBase, "dest")

--- Fresh session against an empty archive cache. The batch is created (curl
--- is loaded) but nothing is transferred unless a test adds a real URL.
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

test.it("prefetch trusts a file already at the destination as complete", function()
	beginSession()
	-- Downloads land in a private part path and are renamed into place, so a file
	-- at destPath is always a complete download — including one another process
	-- renamed in while this session was starting. It must not be re-fetched, and
	-- must not be deleted (a concurrent process may be extracting it right now).
	local dest = path.join(destBase, "leftover.archive")
	fs.write(dest, "complete bytes")

	local status = download.prefetch("https://example.com/x.tar.gz", dest)
	test.equal(status, "done", "a file at the destination must count as cached")
	test.equal(fs.read(dest), "complete bytes", "the file must be left untouched")
	download.finish()
end)

test.it("background trusts a file already at the destination as complete", function()
	beginSession()
	local dest = path.join(destBase, "leftover2.archive")
	fs.write(dest, "complete bytes")

	local status = download.background("https://example.com/y.tar.gz", dest)
	test.equal(status, "done")
	test.equal(fs.read(dest), "complete bytes")
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
