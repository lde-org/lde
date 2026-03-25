local http = require("http")
local process = require("process")
local semver = require("semver")
local json = require("json")
local ansi = require("ansi")
local path = require("path")
local fs = require("fs")
local env = require("env")

local lpm = require("lpm-core")

local releasesUrl = "https://api.github.com/repos/codebycruz/lpm/releases"

local arch = jit.arch == "arm64" and "aarch64" or "x86-64"
local artifactNames = {
	win32 = "lpm-windows-" .. arch .. ".exe",
	linux = "lpm-linux-" .. arch,
	darwin = "lpm-macos-" .. arch
}

---@param args clap.Args
local function upgrade(args)
	if env.var("BOOTSTRAP") then
		ansi.printf("{red}Cannot run upgrade during bootstrap")
		return
	end

	local shouldForce = args:flag("force")
	local shouldNightly = args:flag("nightly")
	local desiredVersion = args:option("version")

	local releaseUrl
	if shouldNightly then
		releaseUrl = releasesUrl .. "/tags/nightly"
	elseif not desiredVersion then
		releaseUrl = releasesUrl .. "/latest"
	else
		releaseUrl = releasesUrl .. "/tags/v" .. desiredVersion
	end

	local out, err = http.get(releaseUrl)
	if not out then
		ansi.printf("{red}Failed to fetch latest release: %s", err)
		return
	end

	local releaseInfo = json.decode(out)
	if not releaseInfo or not releaseInfo.tag_name or not releaseInfo.assets then
		ansi.printf("{red}Invalid release information received")
		return
	end

	local latestVersion = string.match(releaseInfo.tag_name, "v?(%d+%.%d+%.%d+)")

	if not shouldNightly then
		if not latestVersion then
			ansi.printf("{red}Invalid version format in release tag")
			return
		end

		local runningVersion = lpm.global.currentVersion
		if not shouldForce and not desiredVersion and semver.compare(latestVersion, runningVersion) <= 0 then
			ansi.printf("{green}You are already running the latest version (%s)", runningVersion)
			return
		end
	end

	local binLocation = env.execPath()
	if not binLocation then
		ansi.printf("{red}Could not determine current executable path")
		return
	end

	local artifactName = artifactNames[process.platform]
	if not artifactName then
		ansi.printf("{red}No artifact available for platform: %s", process.platform)
		return
	end

	local downloadUrl = nil
	for _, asset in ipairs(releaseInfo.assets) do
		if asset.name == artifactName then
			downloadUrl = asset.browser_download_url
			break
		end
	end

	if not downloadUrl then
		ansi.printf("{red}Could not find download URL for artifact: %s", artifactName)
		return
	end

	local binDir = path.dirname(binLocation)
	local binName = path.basename(binLocation)
	local tempNewLocation = path.join(binDir, binName .. ".new")
	local tempOldLocation = path.join(binDir, binName .. ".old")

	ansi.printf("{green}==> Downloading {white}%s {green}from {cyan}%s", artifactName, downloadUrl)

	-- Download directly to file to avoid output size limits in process.exec
	local downloadSuccess, downloadErr = process.spawn("curl", { "-sL", "-o", tempNewLocation, downloadUrl })
	if not downloadSuccess then
		ansi.printf("{red}Failed to download binary: %s", downloadErr)
		return
	end

	if not fs.exists(tempNewLocation) then
		ansi.printf("{red}Failed to download binary: file not created")
		return
	end

	-- Move current executable to tmp (allows replacement even if running)
	local moveOldSuccess, moveOldErr = fs.move(binLocation, tempOldLocation)
	if not moveOldSuccess then
		fs.delete(tempNewLocation)
		ansi.printf("{red}Failed to move current binary: %s", moveOldErr)
		return
	end

	-- Move new executable to original location
	local moveNewSuccess, moveNewErr = fs.move(tempNewLocation, binLocation)
	if not moveNewSuccess then
		-- Try to restore the old binary
		fs.move(tempOldLocation, binLocation)
		fs.delete(tempNewLocation)
		ansi.printf("{red}Failed to install new binary: %s", moveNewErr)
		return
	end

	if process.platform ~= "win32" then ---@cast fs fs.raw.posix
		fs.chmod(binLocation, tonumber("755", 8))
	end

	-- Clean up old binary
	fs.delete(tempOldLocation)

	if shouldNightly then
		ansi.printf("{green}Successfully upgraded to nightly build!")
	else
		ansi.printf("{green}Successfully upgraded to version %s!", latestVersion)
	end
end

return upgrade
