--- Archive cache and extraction.

const fs = require("fs")
const path = require("path")
const ansi = require("ansi")
const md5 = require("lde-core.util.md5")
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
---@param source rocked.raw.Source? # rockspec source section: md5/dir/file
---@return string archiveDir
---@return string sourceDir # dir holding the source (see sourceDirFor)
function M.getOrInitArchive(url, isOffline, source)
	local archiveDir = M.getArchiveDir(url)
	const marker = path.join(archiveDir, consts.CACHE_MARKER)
	if fs.exists(marker) then
		return archiveDir, M.sourceDirFor(archiveDir, source and source.dir, source and source.file)
	end

	if fs.isdir(archiveDir) then
		-- Legacy cache (written before markers existed) or a run killed between
		-- the atomic move and the marker write: the tree moved into place in one
		-- step, so it is complete — adopt it. A dir is never created up front, so
		-- this cannot pick up another process's in-flight extraction.
		-- Marker-less dirs predate layout tracking: their content is the legacy
		-- (stripped) layout, which is what sourceDirFor then reports.
		fs.write(marker, consts.ARCHIVE_LAYOUT_LEGACY)
		return archiveDir, M.sourceDirFor(archiveDir, source and source.dir, source and source.file)
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

	const expectedMd5 = source and source.md5
	if expectedMd5 and expectedMd5 ~= "" then
		const content = fs.read(archiveFile)
		if content and md5.sumhexa(content) ~= expectedMd5:lower() then
			fs.delete(archiveFile)
			if bar then bar:fail("Downloading " .. filename) end
			lde.error.raise("MD5 check for " .. filename .. " has failed.")
		end
	end

	-- The extracted tree is moved into place by extractArchive, which marks it
	-- complete; nothing is written into the cache dir before that move.
	local ok2, err2 = M.extractArchive(url, archiveFile, archiveDir)
	if not ok2 then
		if bar then bar:fail("Downloading " .. filename) end
		lde.error.raise("Failed to extract archive '" .. url .. "': " .. (err2 or "unknown error"))
	end

	if bar then bar:done("Downloaded " .. filename) end
	return archiveDir, M.sourceDirFor(archiveDir, source and source.dir, source and source.file)
end

--- Cache directory an archive URL extracts into.
---@param url string
function M.getArchiveDir(url)
	return path.join(dirs.getTarCacheDir(), dirs.sanitize(url))
end

--- Layout of an extracted archive: the marker's content when it records one,
--- else inferred from the content and written back. A tree extracted as published
--- holds exactly one directory (the archive's wrapper) and nothing else; a tree
--- extracted by an older lde has the package's own files at the root, because the
--- first path component was stripped. Marker-less legacy caches and dirs created
--- by tests therefore classify correctly.
---@param archiveDir string
---@return string layout
local function archiveLayout(archiveDir)
	const markerPath = path.join(archiveDir, consts.CACHE_MARKER)
	const recorded = fs.read(markerPath)
	if recorded == consts.ARCHIVE_LAYOUT or recorded == consts.ARCHIVE_LAYOUT_LEGACY then
		return recorded
	end

	local entries, dirCount = 0, 0
	local iter = fs.readdir(archiveDir)
	if iter then
		for entry in iter do
			if entry.name ~= consts.CACHE_MARKER then
				entries += 1
				if entry.type == "dir" then dirCount += 1 end
			end
		end
	end
	const layout = (entries == 1 and dirCount == 1) and consts.ARCHIVE_LAYOUT or consts.ARCHIVE_LAYOUT_LEGACY
	fs.write(markerPath, layout)
	return layout
end

--- The directory inside an extracted archive that holds the source, mirroring
--- LuaRocks' find_rockspec_source_dir: the declared `source.dir` when it exists,
--- else the archive's single top-level directory, else the extraction root. A
--- lone .lua/.c file (a single-file rock) also means the root.
---@param archiveDir string
---@param declaredDir string? # rockspec source.dir
---@param declaredFile string? # rockspec source.file (or the URL's basename)
---@return string
function M.sourceDirFor(archiveDir, declaredDir, declaredFile)
	-- Legacy extractions stripped the first path component, so the root already is
	-- the source tree; only layout 2+ archives need unwrapping.
	if archiveLayout(archiveDir) ~= consts.ARCHIVE_LAYOUT then return archiveDir end

	if declaredDir and declaredDir ~= "" then
		const declared = path.join(archiveDir, declaredDir)
		if fs.isdir(declared) then return declared end
		return archiveDir
	end

	const singleFile = declaredFile and declaredFile:match("%.lua$") or declaredFile and declaredFile:match("%.c$")
	if singleFile and fs.isfile(path.join(archiveDir, declaredFile --[[@as string]])) then
		return archiveDir
	end

	-- A package manifest (or a rockspec) at the root means the archive is the
	-- package itself, even when it happens to hold a single directory (the
	-- package's own `src/`): only then is a single top-level directory a wrapper
	-- to unwrap. LuaRocks has no manifest case — its `source.dir` handles it —
	-- but lde archive dependencies point straight at package tarballs.
	for _, manifest in ipairs({ "lde.json", "lpm.json" }) do
		if fs.isfile(path.join(archiveDir, manifest)) then return archiveDir end
	end
	local iter0 = fs.readdir(archiveDir)
	if iter0 then
		for entry in iter0 do
			if entry.type == "file" and entry.name:match("%.rockspec$") then return archiveDir end
		end
	end

	local foundDir, dirCount = nil, 0
	local iter = fs.readdir(archiveDir)
	if iter then
		for entry in iter do
			if entry.type == "dir" and entry.name ~= ".lde-complete" then
				dirCount += 1
				foundDir = entry.name
			end
		end
	end
	if dirCount == 1 then return path.join(archiveDir, foundDir --[[@as string]]) end
	return archiveDir
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
	-- Unpacked as-is: which subdirectory holds the source is decided afterwards by
	-- sourceDirFor (LuaRocks' find_rockspec_source_dir), because stripping the first
	-- path component mangles archives that have no single root directory.
	local ok, err2 = archive.new(archiveFile):extract(tmpDir)

	-- The archive is left in place: it is the shared cache entry the download
	-- renamed into position, and another process may be extracting those same
	-- bytes right now (deleting it here made that process fail with "cannot open").
	if not ok then
		fs.rmdir(tmpDir)
		return nil, err2
	end

	-- An unsupported format extracts to nothing; report it instead of caching an
	-- empty tree that every later run would trust.
	local staged = false
	local iter = fs.readdir(tmpDir)
	if iter then
		for _ in iter do
			staged = true
			break
		end
	end
	if not staged then
		fs.rmdir(tmpDir)
		return nil, "nothing extracted (unsupported archive format?)"
	end

	if fs.move(tmpDir, archiveDir) then
		fs.write(path.join(archiveDir, consts.CACHE_MARKER), consts.ARCHIVE_LAYOUT)
		return true
	end

	-- Another process materialized the same archive first: its tree wins.
	fs.rmdir(tmpDir)
	if fs.exists(archiveDir) then
		-- Another process materialized it first: its layout is authoritative.
		return true
	end
	return nil, "failed to move extracted archive into " .. archiveDir
end

return M
