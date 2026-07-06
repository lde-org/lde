local ansi = require("ansi")
local fs = require("fs")
local path = require("path")

local lde = require("lde-core")

---@param args clap.Args
local function compile(args)
	local outFile = args:option("outfile")

	local pkg, err = lde.Package.open()
	if not pkg then
		ansi.printf("{red}%s", err)
		return
	end

	if not outFile then
		outFile = path.join(pkg:getDir(), pkg:getName())
	end

	if jit.os == "Windows" and string.sub(outFile, -4) ~= ".exe" then
		outFile = outFile .. ".exe"
	end

	local executable = pkg:compile()
	local ok, moveErr = fs.move(executable, outFile)
	if not ok then
		error("Failed to move executable: " .. moveErr)
	end

	-- On Windows, also copy the import library (.a) that was generated alongside
	-- the exe so native dependencies (e.g. lua-sys) can link against it.
	if jit.os == "Windows" then
		local srcImplib  = executable:gsub("%.exe$", ""):gsub("%.out$", "") .. ".a"
		local destImplib = outFile:gsub("%.exe$", "") .. ".a"
		if fs.exists(srcImplib) then
			fs.move(srcImplib, destImplib)
		end
	end

	if jit.os ~= "Windows" then ---@cast fs fs.raw.posix
		fs.chmod(outFile, tonumber("755", 8))
	end

	ansi.printf("{green}Executable created: %s", outFile)
end

return compile
