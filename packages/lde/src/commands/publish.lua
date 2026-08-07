local ansi = require("ansi")
local curl = require("curl-sys")
local git2 = require("git2-sys")
local json = require("json")
local process = require("process")

local lde = require("lde-core")

local REGISTRY_REPO = "https://github.com/lde-org/registry"

---@param s string
local function urlEncode(s)
	return s:gsub("([^%w%-_%.~])", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
end

local function registryRawBase()
	return (REGISTRY_REPO:gsub("%.git$", ""):gsub("^https://github%.com/", "https://raw.githubusercontent.com/"))
end

--- Fetches the live registry portfile for a package, if one exists.
---@param name string
---@return lde.Portfile? portfile # nil when the package has never been published
---@return string? err # transport/parse errors that prevented checking
local function fetchExistingPortfile(name)
	local url = registryRawBase() .. "/master/packages/" .. name .. ".json"

	local res, getErr = curl.get(url)
	if not res then
		return nil, getErr or ("failed to fetch " .. url)
	end
	if res.status == 404 then
		return nil, nil
	end
	if res.status ~= 200 then
		return nil, "registry returned HTTP " .. res.status
	end

	local ok, portfile = pcall(json.decode, res.body)
	if not ok or type(portfile) ~= "table" then
		return nil, "registry returned malformed portfile for '" .. name .. "'"
	end
	return portfile, nil
end

local function openBrowser(url)
	if jit.os == "Windows" then
		-- Empty string before URL is the window title, required when URL contains special chars
		local child = process.spawn("cmd", { "/c", "start", "", url })
		if child then child:wait() end
	elseif jit.os == "OSX" then
		local child = process.spawn("open", { url })
		if child then child:wait() end
	else
		local child = process.spawn("xdg-open", { url })
		if child then child:wait() end
	end
end

---@param args clap.Args
local function publish(args)
	local pkg, err = lde.Package.open()
	if not pkg then
		ansi.printf("{red}%s", err)
		return
	end

	local config = pkg:readConfig()
	local pkgDir = pkg:getDir()

	local repo, repoErr = git2.open(pkgDir)
	if not repo then
		ansi.printf("{red}Could not open git repository: %s", repoErr or "unknown error")
		return
	end

	local gitUrl, urlErr = repo:remoteUrl("origin")
	if not gitUrl then
		ansi.printf("{red}Could not get git remote URL. Is this a git repo with an 'origin' remote?")
		return
	end

	local commit, commitErr = repo:revparse("HEAD")
	if not commit then
		ansi.printf("{red}Could not get current commit. Does this repo have any commits?")
		return
	end

	local branch = repo:currentBranch() or "master"

	-- Preserve previously published version commits: fetch the live portfile
	-- (if any) and merge its versions with the new one. All other fields are
	-- rebuilt fresh from the current package below.
	local existing, fetchErr = fetchExistingPortfile(config.name)
	if fetchErr then
		ansi.printf("{yellow}Could not check registry for existing versions: %s", fetchErr)
	end

	local versions = (existing and type(existing.versions) == "table") and existing.versions or {}
	if versions[config.version] then
		-- Re-publishing the same version: update the pinned commit in place.
		versions[config.version] = commit
	else
		json.addField(versions, config.version, commit)
	end

	local portfile = {}
	json.addField(portfile, "name", config.name)
	json.addField(portfile, "description", config.description)
	json.addField(portfile, "authors", config.authors)
	json.addField(portfile, "git", gitUrl)
	json.addField(portfile, "branch", branch)
	json.addField(portfile, "versions", versions)

	local portfileJson = json.encode(portfile)
	local filename = "packages/" .. config.name .. ".json"
	local url = REGISTRY_REPO .. "/new/master"
		.. "?filename=" .. urlEncode(filename)
		.. "&value=" .. urlEncode(portfileJson)

	ansi.printf("{green}Opening browser to submit {cyan}%s@%s{reset} to the registry...", config.name, config.version)
	openBrowser(url)
end

return publish
