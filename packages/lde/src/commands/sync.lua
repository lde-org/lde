local ansi = require("ansi")
local lde = require("lde-core")

---@param args clap.Args
local function sync(args)
	local pkg, err = lde.Package.open()
	if not pkg then
		lde.error.raise(err)
	end

	local start = ansi.now()
	local opts = { summary = true, locked = args:flag("locked") }

	-- Errors propagate to the CLI boundary, which renders them cleanly.
	pkg:build()
	local runtime = pkg:installDependencies(nil, nil, nil, opts)
	local dev = not args:flag("production") and pkg:installDevDependencies(opts)

	if (runtime and runtime.changed) or (dev and dev.changed) then
		ansi.printf("{green}All dependencies installed successfully.")
	else
		local installs = (runtime and runtime.installs or 0) + (dev and dev.installs or 0)
		local checked = (runtime and runtime.checked or 0) + (dev and dev.checked or 0)
		if checked > 0 then
			local cached = runtime and runtime.cached
			local format = cached
				and "{gray}No changes in %d %s across %d %s (cached) (%s)"
				or "{gray}No changes in %d %s across %d %s (%s)"
			ansi.printf(format,
				installs, installs == 1 and "install" or "installs",
				checked, checked == 1 and "package" or "packages",
				ansi.formatElapsed(ansi.now() - start))
		end
	end
end

return sync
