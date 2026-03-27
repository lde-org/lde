local ansi = require("ansi")

local lde = require("lde-core")
local resolvePackage = require("lde.util.resolve")

---@param args clap.Args
local function install(args)
	-- No flags and no name = install deps for current project
	if not args:option("git") and not args:option("path") and not args:peek() then
		local pkg, err = lde.Package.open()
		if not pkg then
			ansi.printf("{red}%s", err)
			return
		end

		pkg:installDependencies()
		if not args:flag("production") then
			pkg:installDevDependencies()
		end

		ansi.printf("{green}All dependencies installed successfully.")
		return
	end

	local name = args:peek()
	local pkg, err = resolvePackage(args)
	if not pkg then error(err) end

	if name and name:match("^rocks:") then
		lde.global.writeWrapper(pkg:getName(), nil, name)
	else
		lde.global.writeWrapper(pkg:getName(), pkg.dir, pkg:getName())
	end
end

return install
