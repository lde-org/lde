local ansi = require("ansi")
local fs = require("fs")
local process = require("process")
local path = require("path")

local lpm = require("lpm-core")

---@param args clap.Args
local function compile(args)
	local outFile = args:option("outfile")

	local pkg, err = lpm.Package.open()
	if not pkg then
		ansi.printf("{red}%s", err)
		return
	end

	if not outFile then
		outFile = path.join(pkg:getDir(), pkg:getName())
	end

	if process.platform == "win32" and string.sub(outFile, -4) ~= ".exe" then
		outFile = outFile .. ".exe"
	end

	local executable = pkg:compile()
	local ok, err = fs.move(executable, outFile)
	if not ok then
		error("Failed to move executable: " .. err)
	end

	if process.platform ~= "win32" then ---@cast fs fs.raw.posix
		fs.chmod(outFile, tonumber("755", 8))
	end

	ansi.printf("{green}Executable created: %s", outFile)
end

return compile
