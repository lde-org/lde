local ansi = require("ansi")
local fs = require("fs")
local path = require("path")

local lde = require("lde-core")

---@param args clap.Args
local function bundle(args)
	local outFile = args:option("outfile")

	local pkg, err = lde.Package.open()
	if not pkg then
		ansi.printf("{red}%s", err)
		return
	end

	if not outFile then
		outFile = path.join(pkg:getDir(), pkg:getName() .. ".lua")
	end

	pkg:build()
	pkg:installDependencies()

	local result = pkg:bundle({ bytecode = args:flag("bytecode") })
	fs.write(outFile, result)
	ansi.printf("{green}Bundled to %s", outFile)
end

return bundle
