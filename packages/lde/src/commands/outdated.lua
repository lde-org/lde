local ansi = require("ansi")
local semver = require("semver")
local luarocks = require("luarocks")
local lde = require("lde-core")

---@param _args clap.Args
local function outdated(_args)
	local pkg, err = lde.Package.open()
	if not pkg then
		ansi.printf("{red}%s", err)
		return
	end

	local deps = pkg:getDependencies()
	local found = false

	for name, depInfo in pairs(deps) do
		if depInfo.version then
			-- lpm registry dep
			lde.global.syncRegistry()
			local portfile, rerr = lde.global.lookupRegistryPackage(depInfo.name or name)
			if not portfile then
				ansi.printf("{red}%s: %s", name, rerr)
				goto continue
			end

			local latest = depInfo.version ---@type string
			for v in pairs(portfile.versions) do
				if semver.compare(v, latest) > 0 then latest = v end
			end

			if latest ~= depInfo.version then
				ansi.printf("{yellow}%s{reset}  {gray}%s{reset} → {green}%s", name, depInfo.version, latest)
				found = true
			end
		elseif depInfo.luarocks then
			-- luarocks dep: pick latest from manifest
			local manifest, merr = lde.util.getManifest()
			if not manifest then
				ansi.printf("{red}%s: %s", name, merr)
				goto continue
			end

			local latestUrl, _ = luarocks.getRockspecUrl(manifest, depInfo.luarocks)
			if not latestUrl then goto continue end

			-- extract version from url: name-VERSION.rockspec
			local latest = latestUrl:match(depInfo.luarocks .. "%-([^/]+)%.rockspec$")
			local current = depInfo.version

			if latest and current and latest ~= current then
				ansi.printf("{yellow}%s{reset}  {gray}%s{reset} → {green}%s {gray}(luarocks)", name, current, latest)
				found = true
			end
		end
		::continue::
	end

	if not found then
		ansi.printf("{green}All dependencies are up to date.")
	end
end

return outdated
