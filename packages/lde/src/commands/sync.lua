local ansi = require("ansi")
local path = require("path")
local lde = require("lde-core")

---@param args clap.Args
local function sync(args)
	local pkg, err = lde.Package.open()
	if not pkg then
		lde.error.raise(err)
	end ---@cast pkg -nil

	-- --timings collects wall-clock units for the build and writes an HTML
	-- report to target/timings.html; --json switches the report to JSON
	-- (target/timings.json) for machine/LLM consumption. --json implies
	-- collection, so it works standalone too.
	local wantJSON = args:flag("json")
	local timings = nil
	if args:flag("timings") or wantJSON then
		timings = lde.timings
		local ok, version = pcall(require, "lde.version")
		timings.begin({
			command = "sync",
			package = pkg:getName(),
			version = ok and version or nil,
		})
	end

	local start = ansi.now()
	local opts = { summary = true, isLocked = args:flag("locked") }

	-- Errors propagate to the CLI boundary, which renders them cleanly.
	local rootBuild = timings and timings.start("build " .. pkg:getName(), "build") or nil
	pkg:build()
	if timings and rootBuild then timings.finish(rootBuild) end
	local runtime = pkg:installDependencies(nil, nil, nil, opts)
	local dev = not args:flag("production") and pkg:installDevDependencies(opts)

	if (runtime and runtime.hasChanged) or (dev and dev.hasChanged) then
		ansi.printf("{green}All dependencies installed successfully.")
	else
		local installs = (runtime and runtime.installs or 0) + (dev and dev.installs or 0)
		local checked = (runtime and runtime.checked or 0) + (dev and dev.checked or 0)
		if checked > 0 then
			local isCached = runtime and runtime.isCached
			local format = isCached
				and "{gray}No changes in %d %s across %d %s (cached) (%s)"
				or "{gray}No changes in %d %s across %d %s (%s)"
			ansi.printf(format,
				installs, installs == 1 and "install" or "installs",
				checked, checked == 1 and "package" or "packages",
				ansi.formatElapsed(ansi.now() - start))
		end
	end

	if timings then
		local reportPath = path.join(pkg:getModulesDir(), wantJSON and "timings.json" or "timings.html")
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
