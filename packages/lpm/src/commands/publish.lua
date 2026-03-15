local ansi = require("ansi")
local json = require("json")
local process = require("process")

local Package = require("lpm-core.package")

local REGISTRY_REPO = "https://github.com/codebycruz/lpm-registry"

---@param s string
local function urlEncode(s)
	return s:gsub("([^%w%-_%.~])", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
end

local function openBrowser(url)
	if jit.os == "Windows" then
		-- Empty string before URL is the window title, required when URL contains special chars
		process.spawn("cmd", { "/c", "start", "", url })
	elseif jit.os == "OSX" then
		process.spawn("open", { url })
	else
		process.spawn("xdg-open", { url })
	end
end

---@param args string[]
---@param cwd string
---@return string?
local function gitOutput(args, cwd)
	local ok, output = process.exec("git", args, { cwd = cwd })
	if not ok or not output then return nil end
	return output:gsub("%s+$", "")
end

---@param args clap.Args
local function publish(args)
	local pkg, err = Package.open()
	if not pkg then
		ansi.printf("{red}%s", err)
		return
	end

	local config = pkg:readConfig()
	local pkgDir = pkg:getDir()

	local gitUrl = gitOutput({ "remote", "get-url", "origin" }, pkgDir)
	if not gitUrl then
		ansi.printf("{red}Could not get git remote URL. Is this a git repo with an 'origin' remote?")
		return
	end

	local commit = gitOutput({ "rev-parse", "HEAD" }, pkgDir)
	if not commit then
		ansi.printf("{red}Could not get current commit. Does this repo have any commits?")
		return
	end

	local branch = gitOutput({ "rev-parse", "--abbrev-ref", "HEAD" }, pkgDir) or "master"

	local versions = {}
	json.addField(versions, config.version, commit)

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
