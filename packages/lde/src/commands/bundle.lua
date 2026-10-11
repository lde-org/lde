const ansi = require("ansi")
const fs = require("fs")
const path = require("path")

const lde = require("lde-core")

---@param args clap.Args
local function bundle(args)
	local outFile = args:option("outfile")

	const pkg, err = lde.Package.open()
	if not pkg then
		lde.error.raise(err)
	end ---@cast pkg -nil

	if not outFile then
		outFile = path.join(pkg:getDir(), pkg:getName() .. ".lua")
	end

	pkg:build()
	pkg:installDependencies()

	const result = pkg:bundle({ bytecode = args:flag("bytecode") })
	fs.write(outFile, result --[[@as string]])
	ansi.printf("{green}Bundled to %s", outFile)
end

return bundle
