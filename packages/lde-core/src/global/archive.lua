--- Archive cache and extraction.

const fs = require("fs")
const path = require("path")
const ansi = require("ansi")
const util = require("util")

const lde = require("lde-core")
const dirs = require("lde-core.global.dirs")
const consts = require("lde-core.global.consts")
const curl = util.lazy(|| -> require("curl-sys"))
local Archive = util.lazy(|| -> require("archive"))

local M = {}

--- Suffix that keeps a temp cache dir private to this process (tostring of a
--- fresh table yields its address, which is unique while the table lives).
local function uniqueSuffix()
	return tostring({}):match("0x(%x+)$") or tostring(os.time())
end

--- Downloads and extracts an archive URL (.zip, .tar.gz, .tar.bz2, etc.) into the cache.
--- Uses `tar -xf` which auto-detects format on all platforms (bsdtar on Windows 10+).
--- With `offline`, never touches the network: the archive must already be
--- cached, otherwise it errors.
---
--- Failure-safe: a failed download/extract removes the partially-created cache dir
--- so the next run re-downloads instead of trusting an empty/partial dir. A
--- concurrent install may finish (and delete the .archive file) while this
--- download is in flight; the extracted dir is reused in that case.
---@param url string
---@param isOffline boolean?
function M.getOrInitArchive(url, isOffline)
	local archiveDir = M.getArchiveDir(url)
	const marker = path.join(archiveDir, consts.CACHE_MARKER)
	if fs.exists(marker) then return archiveDir end

	if fs.isdir(archiveDir) then
		-- Legacy cache (written before markers existed) or a run killed between
		-- the atomic move and the marker write: the tree moved into place in one
		-- step, so it is complete — adopt it. A dir is never created up front, so
		-- this cannot pick up another process's in-flight extraction.
		fs.write(marker, "")
		return archiveDir
	end

	if isOffline then
		lde.error.raise("offline: archive is not cached locally (run once online to cache it): " .. url)
	end

	const filename = url:match("([^/]+)$") or url
	local bar = lde.isVerbose ? ansi.progress("Downloading " .. filename) : nil
	-- Per-process download path: two installs fetching the same URL must not
	-- write (and truncate) the same file.
	local archiveFile = archiveDir .. ".archive" .. uniqueSuffix()

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

	-- One retry: GitHub release assets redirect to expiring CDN URLs, which can
	-- fail transiently on the first attempt.
	local ok, dlErr = curl().download(url, archiveFile, dlOpts)
	if not ok then
		ok, dlErr = curl().download(url, archiveFile, dlOpts)
	end
	if not ok then
		fs.delete(archiveFile)
		if bar then bar:fail("Downloading " .. filename) end
		lde.error.raise("Failed to download archive '" .. url .. "': " .. (dlErr or "unknown error"))
	end

	-- The extracted tree is moved into place by extractArchive, which marks it
	-- complete; nothing is written into the cache dir before that move.
	local ok2, err2 = M.extractArchive(url, archiveFile, archiveDir)
	if not ok2 then
		if bar then bar:fail("Downloading " .. filename) end
		lde.error.raise("Failed to extract archive '" .. url .. "': " .. (err2 or "unknown error"))
	end

	if bar then bar:done("Downloaded " .. filename) end
	return archiveDir
end

--- Cache directory an archive URL extracts into.
---@param url string
function M.getArchiveDir(url)
	return path.join(dirs.getTarCacheDir(), dirs.sanitize(url))
end

--- Extract a downloaded archive file into its cache directory. Extraction
--- happens in a sibling temp dir that is moved into place afterwards, so two
--- processes unpacking the same URL cannot observe (or produce) a half-extracted
--- tree; the loser of the race drops its temp dir and uses the winner's.
---@param url string
---@param archiveFile string
---@param archiveDir string
---@return boolean? ok
---@return string? err
function M.extractArchive(url, archiveFile, archiveDir)
	if not fs.exists(archiveFile) then
		return nil, "missing downloaded archive: " .. archiveFile
	end

	const tmpDir = archiveDir .. ".tmp" .. uniqueSuffix()
	const archive = Archive()
	local ok, err2
	if url:match("%.src%.rock$") then
		-- .src.rock is a zip with no single top-level dir.
		ok, err2 = archive.new(archiveFile):extract(tmpDir)
	else
		ok, err2 = archive.new(archiveFile):extract(tmpDir, { stripComponents = true })
	end

	fs.delete(archiveFile)
	if not ok then
		fs.rmdir(tmpDir)
		return nil, err2
	end

	if fs.move(tmpDir, archiveDir) then
		fs.write(path.join(archiveDir, consts.CACHE_MARKER), "")
		return true
	end

	-- Another process materialized the same archive first: its tree wins.
	fs.rmdir(tmpDir)
	if fs.exists(archiveDir) then
		fs.write(path.join(archiveDir, consts.CACHE_MARKER), "")
		return true
	end
	return nil, "failed to move extracted archive into " .. archiveDir
end

return M
