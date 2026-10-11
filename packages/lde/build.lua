-- build.lua — generates target/lde/version.lua with the build version string.
--
-- Format: "<semver>-nightly+<short-hash>"  (e.g. "0.9.1-nightly+a1b2c3d")
-- Falls back to "<semver>-dev" if git is unavailable (e.g. in a source tarball).
-- When LDE_RELEASE is set, emits the bare "<semver>" with no commit hash.

const build = require("lde-build")

const BASE_VERSION = "0.11.0"

const releaseEnv = os.getenv("LDE_RELEASE")
const release = releaseEnv ~= nil and releaseEnv ~= ""

-- Use io.popen so this works in both lde-build and minilde contexts without
-- needing the process package. Note popen shells out via cmd.exe on Windows,
-- so the stderr redirect must be platform-appropriate.
local hash
if not release then
	const null = jit.os == "Windows" ? "2>nul" : "2>/dev/null"
	const handle = io.popen("git rev-parse --short=7 HEAD " .. null)
	if handle then
		const out = handle:read("*l")
		handle:close()
		if out and out:match("^%x+$") then
			hash = out
		end
	end
end

local version
if release then
	version = BASE_VERSION
elseif hash then
	version = BASE_VERSION .. "-nightly+" .. hash
else
	version = BASE_VERSION .. "-dev"
end

build:write("version.lua", string.format("return %q\n", version))
