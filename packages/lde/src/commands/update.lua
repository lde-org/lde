local ansi = require("ansi")

local lde = require("lde-core")

---@param results table<string, { updated: boolean, message: string }>
local function printResults(results)
	for name, result in pairs(results) do
		if result.updated then
			ansi.printf("{green}  %s: %s", name, result.message)
		else
			ansi.printf("{gray}  %s: %s", name, result.message)
		end
	end
end

---@param args clap.Args
local function update(args)
	local pkg, err = lde.Package.open()
	if not pkg then
		ansi.printf("{red}%s", err)
		return
	end

	local name = args:pop()

	if name then
		local deps = pkg:getDependencies()
		local devDeps = pkg:getDevDependencies()
		local depInfo = deps[name] or devDeps[name]

		if not depInfo then
			ansi.printf("{red}Unknown dependency: %s", name)
			return
		end

		local results = pkg:updateDependencies({ [name] = depInfo })
		printResults(results)
	else
		local results = pkg:updateDependencies()
		local devResults = pkg:updateDevDependencies()

		for k, v in pairs(devResults) do
			results[k] = v
		end

		printResults(results)
	end
end

return update
