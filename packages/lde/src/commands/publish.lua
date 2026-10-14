const ansi = require("ansi")
const curl = require("curl-sys")
const json = require("json")
const process = require("process")

const lde = require("lde-core")

const REGISTRY_REPO = "https://github.com/lde-org/registry"

---@param s string
local function urlEncode(s)
	return s:gsub("([^%w%-_%.~])", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
end

local function registryRawBase()
	return (REGISTRY_REPO:gsub("%.git$", ""):gsub("^https://github%.com/", "https://raw.githubusercontent.com/"))
end

-- The registry clones over HTTPS; non-SSH URLs pass through unchanged.
---@param url string
---@return string
local function toHttpsUrl(url)
	const host, path = url:match("^git@([^:]+):(.+)$")
	if host and path then
		return "https://" .. host .. "/" .. path
	end
	const protoHost, protoPath = url:match("^ssh://git@([^/]+)/(.+)$")
	if protoHost and protoPath then
		return "https://" .. protoHost .. "/" .. protoPath
	end

	return url
end

---@param name string
---@return lde.Portfile? portfile # nil when the package has never been published
---@return string? err # transport/parse errors that prevented checking
local function fetchExistingPortfile(name)
	local url = registryRawBase() .. "/master/packages/" .. name .. ".json"

	const res, getErr = curl.get(url)
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

---@param url string
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
	const pkg, err = lde.Package.open()
	if not pkg then
		lde.error.raise(err)
	end ---@cast pkg -nil

	const config = pkg:readConfig()
	const pkgDir = pkg:getDir()

	-- The registry enforces strict naming rules; fail here instead of letting the bot reject the issue.
	const nameErr = lde.global.validatePackageName(config.name)
	if nameErr then
		lde.error.raise("Cannot publish: " .. nameErr)
	end

	const repo, repoErr = lde.global.openEnclosingRepo(pkgDir)
	if not repo then
		lde.error.raise("Could not find a git repository for this package: " .. (repoErr or "unknown error"))
	end ---@cast repo -nil

	const gitUrl =  repo:remoteUrl("origin")
	if not gitUrl then
		lde.error.raise("Could not get git remote URL. Is this a git repo with an 'origin' remote?")
	end ---@cast gitUrl -nil

	const commit =  repo:revparse("HEAD")
	if not commit then
		lde.error.raise("Could not get current commit. Does this repo have any commits?")
	end

	const branch = repo:currentBranch() or "master"

	-- Preserve previously published version commits: merge the live portfile's versions with the new one; other fields are rebuilt from the current package.
	const existing, fetchErr = fetchExistingPortfile(config.name)
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
	json.addField(portfile, "git", toHttpsUrl(gitUrl))
	json.addField(portfile, "branch", branch)
	json.addField(portfile, "versions", versions)

	const portfileJson = json.encode(portfile)
	local filename = "packages/" .. config.name .. ".json"
	-- Keep the "/" of namespaced names (packages/ns/pkg.json) unencoded so GitHub creates the nested directory, not a %2F-named file.
	const encodedFilename = urlEncode(filename):gsub("%%2F", "/")
	local url = REGISTRY_REPO .. "/new/master"
		.. "?filename=" .. encodedFilename
		.. "&value=" .. urlEncode(portfileJson)

	ansi.printf("{green}Opening browser to submit {cyan}%s@%s{reset} to the registry...", config.name, config.version)
	openBrowser(url)
end

return publish
