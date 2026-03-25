local ansi = require("ansi")
local env = require("env")
local fs = require("fs")
local git = require("git")
local path = require("path")
local process = require("process")

local lpm = require("lpm-core")

--- Parses a GitHub /tree/<branch> URL into a clone URL and branch.
---@param url string
---@return string cloneUrl
---@return string? branch
local function parseGitUrl(url)
	local base, branch = url:match("^(https://github%.com/[^/]+/[^/]+)/tree/(.+)$")
	if base and branch then
		return base .. ".git", branch
	end

	return url, nil
end

--- Derives a cache-friendly repo name from a git URL.
---@param url string
---@return string
local function repoNameFromUrl(url)
	return url:match("([^/]+)%.git$") or url:match("([^/]+)$")
end

--- Clones or retrieves a cached git repo directory, with optional branch support.
---@param repoName string
---@param cloneUrl string
---@param branch string?
---@return string repoDir
local function getOrCloneRepo(repoName, cloneUrl, branch)
	local safeName = repoName
	if branch then
		safeName = repoName .. "-" .. branch
	end

	local repoDir = lpm.global.getGitRepoDir(safeName)
	if not fs.exists(repoDir) then
		local ok, err = git.clone(cloneUrl, repoDir, branch)
		if not ok then
			error("Failed to clone git repository: " .. (err or "unknown error"))
		end
	end

	return repoDir
end

--- Finds a named package inside a directory by scanning for lpm.json files.
---@param dir string
---@param name string
---@return lpm.Package?
---@return string?
local function findNamedPackageIn(dir, name)
	for _, config in ipairs(fs.scan(dir, "**" .. path.separator .. "lpm.json")) do
		local parentDir = path.join(dir, path.dirname(config))
		local pkg = lpm.Package.open(parentDir)
		if pkg and pkg:getName() == name then
			return pkg, nil
		end
	end

	return nil, "No package named '" .. name .. "' found in: " .. dir
end

--- Writes the platform-appropriate wrapper script into ~/.lpm/tools/.
---@param toolName string
---@param packageDir string  absolute path to the package root (where lpm.json lives)
---@param packageName string the lpm package name
local function writeWrapper(toolName, packageDir, packageName)
	local toolsDir = lpm.global.getToolsDir()

	if process.platform == "win32" then
		local wrapperPath = path.join(toolsDir, toolName .. ".cmd")
		local content = "@echo off\r\nlpm x --path \"" .. packageDir .. "\" " .. packageName .. " %*\r\n"
		if not fs.write(wrapperPath, content) then
			error("Failed to write wrapper script: " .. wrapperPath)
		end
		ansi.printf("{green}Installed tool '%s' -> %s", toolName, wrapperPath)
	else
		local wrapperPath = path.join(toolsDir, toolName)
		local content = "#!/bin/sh\nexec lpm x --path '" .. packageDir .. "' " .. packageName .. " \"$@\"\n"
		if not fs.write(wrapperPath, content) then
			error("Failed to write wrapper script: " .. wrapperPath)
		end
		local ok, err = process.spawn("chmod", { "+x", wrapperPath })
		if not ok then
			error("Failed to make wrapper executable: " .. (err or "unknown error"))
		end
		ansi.printf("{green}Installed tool '%s' -> %s", toolName, wrapperPath)
	end
end

---@param args clap.Args
local function install(args)
	local gitUrl = args:option("git")
	local localPath = args:option("path")

	if gitUrl then
		-- lpm install [package-name] --git <url>
		-- --git is consumed above; package-name is the next positional arg if any
		local cloneUrl, branch = parseGitUrl(gitUrl)
		local repoName = repoNameFromUrl(cloneUrl)
		local repoDir = getOrCloneRepo(repoName, cloneUrl, branch)

		local packageName = args:pop()
		local pkg, err ---@type lpm.Package?, string?
		if packageName then
			pkg, err = findNamedPackageIn(repoDir, packageName)
		else
			pkg, err = lpm.Package.open(repoDir)
		end

		if not pkg then error(err) end
		writeWrapper(pkg:getName(), pkg.dir, pkg:getName())
	elseif localPath then
		-- lpm install --path <dir>  (no package-name: the path IS the package)
		local resolved = path.isAbsolute(localPath) and localPath or path.resolve(env.cwd(), localPath)

		local pkg, err = lpm.Package.open(resolved)
		if not pkg then error(err) end
		writeWrapper(pkg:getName(), pkg.dir, pkg:getName())
	else
		local name = args:pop()
		if name then
			-- lpm install <name>[@<version>]: install a tool from the registry
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
			writeWrapper(pkg:getName(), pkg.dir, pkg:getName())
		else
			-- No name, no --git, no --path: install project dependencies
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
