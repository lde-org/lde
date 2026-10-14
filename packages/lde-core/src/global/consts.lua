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

return M
