const ansi = require("ansi")
const fs = require("fs")
const path = require("path")

const lde = require("lde-core")
const sea = require("sea")

---@param args clap.Args
local function bundle(args)
	local outFile = args:option("outfile")
	const targetName = args:option("target")

	-- Validate the target first so a typo fails before any build work.
	if targetName then
		const resolved, terr = sea.getTarget(targetName)
		if not resolved then
			lde.error.raise(terr)
		end ---@cast resolved -nil
		if resolved.kind == "apk" then
			lde.error.raise("Cannot bundle for " .. targetName .. ": an APK is made by `lde compile`, use android-aarch64 or android-x86-64")
		end
	end

	const pkg, err = lde.Package.open()
	if not pkg then
		lde.error.raise(err)
	end ---@cast pkg -nil

	if not outFile then
		local name = pkg:getName()
		-- A bundle for another machine is named for it, so bundles for several targets can sit side by side.
		if targetName then name = name .. "-" .. targetName end
		outFile = path.join(pkg:getDir(), name .. ".lua")
	end

	-- A host bundle's dependencies are built here; a target's are built by `bundle` itself, which
	-- has to set the target before anything is built for it.
	if not targetName then
		pkg:build()
		pkg:installDependencies()
	end

	const result = pkg:bundle({ bytecode = args:flag("bytecode"), target = targetName })
	fs.write(outFile, result --[[@as string]])
	ansi.printf("{green}Bundled to %s", outFile)
end

return bundle
