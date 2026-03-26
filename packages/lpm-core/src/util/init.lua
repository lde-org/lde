local util = {}

local http = require("http")
local git = require("git")
local rocked = require("rocked")
local lpm = require("lpm-core")
local luarocks = require("luarocks")

--- Fetches a rockspec URL, parses it, and opens the package from its source.
---@param name string # Used for error messages and git cache key
---@param url string # Rockspec URL
---@param branch string?
---@param commit string?
---@return lpm.Package?, lpm.Lockfile.Dependency?, string?
function util.openRockspecUrl(name, url, branch, commit)
	local content, fetchErr = http.get(url)
	if not content then
		return nil, nil, "Failed to fetch rockspec: " .. (fetchErr or "")
	end

	local ok, spec = rocked.parse(content)
	if not ok then
		return nil, nil, "Failed to parse rockspec: " .. tostring(spec)
	end ---@cast spec rocked.raw.Output

	local sourceUrl = spec.source.url
	local sourceTag = spec.source.tag

	---@type string, lpm.Lockfile.Dependency
	local dir, lockEntry
	if sourceUrl:match("^git") then
		sourceUrl = sourceUrl:gsub("^git%+", "")
		dir = lpm.global.getOrInitGitRepo(name, sourceUrl, branch or sourceTag, commit)
		lockEntry = { git = sourceUrl, commit = select(2, git.getCommitHash(dir)) or commit }
	elseif sourceUrl:match("^https?://") then
		dir = lpm.global.getOrInitArchive(sourceUrl)
		lockEntry = { archive = sourceUrl, rockspec = url }
	else
		return nil, nil, "Unsupported source for '" .. name .. "': " .. sourceUrl
	end

	local pkg, err = lpm.Package.openRockspec(dir, url)
	return pkg, lockEntry, err
end

--- Resolves a luarocks package name/version to a Package via the luarocks registry.
---@param name string
---@param version string?
---@return lpm.Package?, lpm.Lockfile.Dependency?, string?
function util.openLuarocksPackage(name, version)
	local url, err = luarocks.getRockspecUrl(name, version)
	if not url then return nil, nil, err end
	return util.openRockspecUrl(name, url)
end

return util
