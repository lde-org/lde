local ansi = require("ansi")
local fs = require("fs")
local path = require("path")

local lde = require("lde-core")
local sea = require("sea")

---@param args clap.Args
local function compile(args)
	local outFile = args:option("outfile")
	local targetName = args:option("target")

	-- Validate the target before opening the package / building, so a typo
	-- fails instantly and the default output name can carry the target.
	local target
	if targetName then
		local resolved, terr = sea.getTarget(targetName)
		if not resolved then
			lde.error.raise(terr)
		end ---@cast resolved -nil
		target = resolved
	end

	local pkg, err = lde.Package.open()
	if not pkg then
		lde.error.raise(err)
	end ---@cast pkg -nil

	-- A --target matching the host is a native build (same naming); only a
	-- genuine cross compile gets the target in the default output name.
	local isCross = false
	if target and not sea.isHostTarget(target) then
		isCross = true
	end

	if not outFile then
		outFile = path.join(pkg:getDir(), pkg:getName())
		if isCross then outFile = outFile .. "-" .. targetName end
	end

	-- Windows targets get .exe, whether native (host Windows) or cross. A
	-- host-matching target has the host platform, so either way the target's
	-- platform is the one the binary runs on.
	local hostPlatform = jit.os == "Windows" and "windows" or jit.os == "OSX" and "macos" or "linux"
	local platform
	if target then
		platform = target.platform
	else
		platform = hostPlatform
	end
	if platform == "windows" and string.sub(outFile, -4) ~= ".exe" then
		outFile = outFile .. ".exe"
	end

	local executable = pkg:compile(targetName)
	local ok, moveErr = fs.move(executable, outFile)
	if not ok then
		lde.error.raise("Failed to move executable: " .. moveErr)
	end

	if jit.os ~= "Windows" then ---@cast fs fs.raw.posix
		fs.chmod(outFile, tonumber("755", 8))
	end

	ansi.printf("{green}Executable created: %s", outFile)
end

return compile
