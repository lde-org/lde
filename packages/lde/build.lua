-- build.lua — generates target/lde/version.lua with the build version string.
--
-- Format: "<semver>-nightly+<short-hash>"  (e.g. "0.9.1-nightly+a1b2c3d")
-- Falls back to "<semver>-dev" if git is unavailable (e.g. in a source tarball).

local build = require("lde-build")

local BASE_VERSION = "0.10.0"

-- Use io.popen so this works in both lde-build and minilde contexts without
-- needing the process package. Note popen shells out via cmd.exe on Windows,
-- so the stderr redirect must be platform-appropriate.
local hash
do
	local null = jit.os == "Windows" and "2>nul" or "2>/dev/null"
	local handle = io.popen("git rev-parse --short=7 HEAD " .. null)
	if handle then
		local out = handle:read("*l")
		handle:close()
		if out and out:match("^%x+$") then
			hash = out
		end
	end
end

local version = hash
	and (BASE_VERSION .. "-nightly+" .. hash)
	or  (BASE_VERSION .. "-dev")

build:write("version.lua", string.format("return %q\n", version))
