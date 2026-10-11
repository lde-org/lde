const ansi = require("ansi")

const lde = require("lde-core")

---@param results table<string, { updated: boolean, message: string }>
local function printResults(results)
	const names = {}
	for name in pairs(results) do
		names[#names + 1] = name
	end
	table.sort(names)

	for _, name in ipairs(names) do
		const result = results[name]
		if result.updated then
			ansi.printf("{green}  %s: %s", name, result.message)
		end
	end
end

---@param results table<string, { updated: boolean, message: string }>
---@param elapsed number
local function printSummary(results, elapsed)
	local total = 0
	local updated = 0
	for _, result in pairs(results) do
		total += 1
		if result.updated then updated = updated + 1 end
	end

	local status = updated == 0 and "no changes" or (updated .. " updated")
	if updated > 0 then
		io.write("\n")
	end

	local installWord = total == 1 and "install" or "installs"
	local packageWord = total == 1 and "package" or "packages"
	ansi.printf("{gray}Checked %d %s across %d %s (%s) [%s]",
		total, installWord, total, packageWord, status, ansi.formatElapsed(elapsed))
end

---@param args clap.Args
local function update(args)
	const startTime = ansi.now()
	const pkg, err = lde.Package.open()
	if not pkg then
		lde.error.raise(err)
	end ---@cast pkg -nil

	local name = args:pop()

	if name then
		const deps = pkg:getDependencies()
		const devDeps = pkg:getDevDependencies()
		const depInfo = deps[name] or devDeps[name]

		if not depInfo then
			lde.error.raise("Unknown dependency: " .. name)
		end

		local results = pkg:updateDependencies({ [name] = depInfo })
		printResults(results)
		printSummary(results, ansi.now() - startTime)
	else
		local results = pkg:updateDependencies()
		const devResults = pkg:updateDevDependencies()

		for k, v in pairs(devResults) do
			results[k] = v
		end

		printResults(results)
		printSummary(results, ansi.now() - startTime)
	end
end

return update
