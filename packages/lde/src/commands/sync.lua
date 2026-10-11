const ansi = require("ansi")
const path = require("path")
const lde = require("lde-core")

---@param args clap.Args
local function sync(args)
	const pkg, err = lde.Package.open()
	if not pkg then
		lde.error.raise(err)
	end ---@cast pkg -nil

	-- --timings collects wall-clock units for the build and writes an HTML
	-- report to target/timings.html; --json switches the report to JSON
	-- (target/timings.json) for machine/LLM consumption. --json implies
	-- collection, so it works standalone too.
	const wantJSON = args:flag("json")
	local timings = nil
	if args:flag("timings") or wantJSON then
		timings = lde.timings
		local ok, version = pcall(require, "lde.version")
		timings.begin({
			command = "sync",
			package = pkg:getName(),
			version = ok ? version : nil,
		})
	end

	const start = ansi.now()
	const opts = { summary = true, isLocked = args:flag("locked") }

	-- Errors propagate to the CLI boundary, which renders them cleanly.
	const rootBuild = timings ? timings.start("build " .. pkg:getName(), "build") : nil
	pkg:build()
	if timings and rootBuild then timings.finish(rootBuild) end
	const runtime = pkg:installDependencies(nil, nil, nil, opts)
	const dev = args:flag("production") ? nil : pkg:installDevDependencies(opts)

	if (runtime and runtime.hasChanged) or (dev and dev.hasChanged) then
		ansi.printf("{green}All dependencies installed successfully.")
	else
		local installs = (runtime?.installs ?? 0) + (dev?.installs ?? 0)
		local checked = (runtime?.checked ?? 0) + (dev?.checked ?? 0)
		if checked > 0 then
			const isCached = runtime?.isCached
			local format = isCached
				and "{gray}No changes in %d %s across %d %s (cached) (%s)"
				or "{gray}No changes in %d %s across %d %s (%s)"
			ansi.printf(format,
				installs, installs == 1 ? "install" : "installs",
				checked, checked == 1 ? "package" : "packages",
				ansi.formatElapsed(ansi.now() - start))
		end
	end

	if timings then
		const reportPath = path.join(pkg:getModulesDir(), wantJSON and "timings.json" or "timings.html")
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
end

return sync
