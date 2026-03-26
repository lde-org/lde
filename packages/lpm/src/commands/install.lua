local ansi = require("ansi")

local lpm = require("lpm-core")
local resolvePackage = require("lpm.util.resolve")

---@param args clap.Args
local function install(args)
	-- No flags and no name = install deps for current project
	if not args:option("git") and not args:option("path") and not args:peek() then
		local pkg, err = lpm.Package.open()
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
		lpm.global.writeWrapper(pkg:getName(), nil, name)
	else
		lpm.global.writeWrapper(pkg:getName(), pkg.dir, pkg:getName())
	end
end

return install
