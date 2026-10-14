--- Shared cache constants.

local M = {}

--- Total-time budget for a single download transfer. curl-sys exposes no
--- default timeout, so a server that accepts the connection but never
--- finishes the body (or a half-open connection) would block forever; the
--- timeout turns that into a per-dependency failure instead of a hang.
M.DOWNLOAD_TIMEOUT = 120 -- seconds

--- Marker written into a cache dir (git checkout, extracted archive) once it is
--- fully materialized. Existence alone is not proof of completeness: a killed
--- run leaves a half-extracted tree that the next run would otherwise trust.
M.CACHE_MARKER = ".lde-complete"

--- Layout of an extracted archive, recorded as the marker's content. "1" (and an
--- empty marker) means the legacy layout: the first path component was stripped
--- during extraction, so the extraction root is the source tree. "2" keeps the
--- archive as published and resolves the source directory afterwards.
M.ARCHIVE_LAYOUT = "2"
M.ARCHIVE_LAYOUT_LEGACY = "1"

return M
