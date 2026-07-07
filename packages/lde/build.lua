-- build.lua — generates target/lde/version.lua with the build version string.
--
-- Format: "<semver>-nightly+<short-hash>"  (e.g. "0.9.1-nightly+a1b2c3d")
-- Falls back to "<semver>-dev" if git is unavailable (e.g. in a source tarball).

local build = require("lde-build")

local BASE_VERSION = "0.9.1"

-- Try to get the short commit hash via git.
local hash
do
	local ok, code, stdout = pcall(function()
		local process = require("process")
		local c, out, _ = process.exec("git", { "rev-parse", "--short=7", "HEAD" })
		return c, out
	end)

	if ok and code == 0 and stdout and #stdout:gsub("%s", "") > 0 then
		hash = stdout:gsub("%s+", "")
	end
end

local version = hash
	and (BASE_VERSION .. "-nightly+" .. hash)
	or  (BASE_VERSION .. "-dev")

build:write("version.lua", string.format("return %q\n", version))
