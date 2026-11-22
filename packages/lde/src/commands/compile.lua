const ansi = require("ansi")
const fs = require("fs")
const path = require("path")

const lde = require("lde-core")
const sea = require("sea")

---@param args clap.Args
local function compile(args)
	const wantJSON = args:flag("json")
	local timings = nil
	if args:flag("timings") or wantJSON then
		timings = lde.timings
	end

	local outFile = args:option("outfile")
	const targetName = args:option("target")
	const isShared = args:flag("shared")

	-- Validate the target first so a typo fails before any build work.
	local target
	if targetName then
		const resolved, terr = sea.getTarget(targetName)
		if not resolved then
			lde.error.raise(terr)
		end ---@cast resolved -nil
		target = resolved
	end

	const pkg, err = lde.Package.open()
	if not pkg then
		lde.error.raise(err)
	end ---@cast pkg -nil

	if timings then
		local ok, version = pcall(require, "lde.version")
		timings.begin({
			command = "compile",
			package = pkg:getName(),
			version = ok ? version : nil,
		})
	end

	-- Only a genuine cross compile gets the target in the default output name.
	local isCross = false
	if target and not sea.isHostTarget(target) then
		isCross = true
	end

	const isAPK = target ~= nil and target.kind == "apk"

	if not outFile then
		outFile = path.join(pkg:getDir(), pkg:getName())
		if isAPK then
			outFile = outFile .. ".apk"
		elseif isCross then
			outFile = outFile .. "-" .. targetName
		end
	end

	const hostPlatform = jit.os == "Windows" and "windows"
		or jit.os == "OSX" and "macos"
		or jit.os == "BSD" and "freebsd"
		or "linux"
	local platform
	if target then
		platform = target.platform
	else
		platform = hostPlatform
	end
	-- Windows targets get .exe whether native or cross; shared libraries get the platform's library suffix.
	const ext = isShared
		and (platform == "windows" and ".dll" or platform == "macos" and ".dylib" or ".so")
		or (platform == "windows" and ".exe" or "")
	if ext ~= "" and string.sub(outFile, -#ext) ~= ext then
		outFile = outFile .. ext
	end

	local executable = pkg:compile(targetName, { shared = isShared })

	-- Stage beside the destination so the final move is a same-device rename (a cross-device copy would fail with ETXTBSY).
	local staged = outFile .. ".tmp"
	local ok, moveErr = fs.move(executable, staged)
	if not ok then
		lde.error.raise("Failed to move executable: " .. moveErr)
	end

	const finalOk, finalErr = fs.move(staged, outFile)
	if not finalOk then
		fs.delete(staged)
		lde.error.raise("Failed to move executable: " .. finalErr)
	end

	if isAPK then
		if jit.os ~= "Windows" then ---@cast fs fs.raw.posix
			fs.chmod(outFile, tonumber("644", 8))
		end
		ansi.printf("{green}APK created: %s", outFile)
		return
	elseif jit.os ~= "Windows" then ---@cast fs fs.raw.posix
		fs.chmod(outFile, tonumber("755", 8))
	end

	if timings then
		const reportPath = path.join(pkg:getModulesDir(), wantJSON ? "timings.json" : "timings.html")
		local okWrite, werr
		if wantJSON then
			okWrite, werr = timings.writeJSON(reportPath)
		else
			okWrite, werr = timings.writeHTML(reportPath)
		end
		if not okWrite then
			lde.error.raise("Failed to write timings report: " .. (werr or "unknown error"))
		end
		ansi.printf("{green}Timings report: {bold}%s", reportPath)
	end

	ansi.printf(isShared and "{green}Shared library created: %s" or "{green}Executable created: %s", outFile)
end

return compile
