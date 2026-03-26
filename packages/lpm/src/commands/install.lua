local ansi = require("ansi")
local env = require("env")
local http = require("http")
local luarocks = require("luarocks")
local path = require("path")
local rocked = require("rocked")

local lpm = require("lpm-core")

---@param args clap.Args
local function install(args)
	local gitUrl = args:option("git")
	local localPath = args:option("path")

	if gitUrl then
		local cloneUrl, branch = lpm.global.parseGitUrl(gitUrl)
		local repoName = lpm.global.repoNameFromUrl(cloneUrl)
		local repoDir = lpm.global.getOrCloneRepo(repoName, cloneUrl, branch)

		local packageName = args:pop()
		local pkg, err
		if packageName then
			pkg, err = lpm.global.findNamedPackageIn(repoDir, packageName)
		else
			pkg, err = lpm.Package.open(repoDir)
		end

		if not pkg then error(err) end
		lpm.global.writeWrapper(pkg:getName(), pkg.dir, pkg:getName())
	elseif localPath then
		local resolved = path.isAbsolute(localPath) and localPath or path.resolve(env.cwd(), localPath)

		local pkg, err = lpm.Package.open(resolved)
		if not pkg then error(err) end
		lpm.global.writeWrapper(pkg:getName(), pkg.dir, pkg:getName())
	else
		local name = args:pop()
		if name then
			if name:match("^rocks:") then
				local rocksName, versionStr = name:match("^rocks:([^@]+)@?(.*)$")
				versionStr = versionStr ~= "" and versionStr or nil

				local url, err = luarocks.getRockspecUrl(rocksName, versionStr)
				if not url then error(err) end

				local content, fetchErr = http.get(url)
				if not content then error("Failed to fetch rockspec: " .. (fetchErr or "")) end

				local ok, spec = rocked.parse(content)
				if not ok then error("Failed to parse rockspec: " .. tostring(spec)) end
				---@cast spec rocked.raw.Output

				local sourceUrl = spec.source.url
				local pkg, pkgErr
				if sourceUrl:match("^git") then
					sourceUrl = sourceUrl:gsub("^git%+", "")
					local repoDir = lpm.global.getOrInitGitRepo(rocksName, sourceUrl)
					pkg, pkgErr = lpm.Package.openRockspec(repoDir)
				elseif sourceUrl:match("^https?://") then
					local archiveDir = lpm.global.getOrInitArchive(sourceUrl)
					pkg, pkgErr = lpm.Package.openRockspec(archiveDir)
				else
					error("Unsupported source for luarocks package '" .. rocksName .. "': " .. sourceUrl)
				end

				if not pkg then error(pkgErr) end
				lpm.global.writeWrapper(rocksName, pkg.dir, pkg:getName())
				return
			end

			local packageName, versionStr = name:match("^([^@]+)@(.+)$")
			if not packageName then packageName = name end

			lpm.global.syncRegistry()
			local portfile, err = lpm.global.lookupRegistryPackage(packageName)
			if not portfile then error(err) end

			local _, commit = lpm.global.resolveRegistryVersion(portfile, versionStr or nil)
			local repoDir = lpm.global.getOrInitGitRepo(packageName, portfile.git, portfile.branch, commit)

			local pkg
			pkg, err = lpm.Package.open(repoDir)
			if not pkg then error(err) end
			lpm.global.writeWrapper(pkg:getName(), pkg.dir, pkg:getName())
		else
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
		end
	end
end

return install
