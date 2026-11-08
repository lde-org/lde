-- Portfile v2 construction: ordered fields, semver-sorted versions, per-version
-- source overrides and normalized tags. Kept pure so publishing tests never
-- need the network.
const json = require("json")
const semver = require("semver")

local portfile = {}

portfile.MAX_TAGS = 10
portfile.MAX_TAG_LENGTH = 32
portfile.TAG_PATTERN = "^[a-z][a-z0-9-]{0,31}$" -- displayed in errors; Lua patterns have no {n,m}

---@param tag string
---@return boolean
local function isValidTag(tag)
	-- Lua patterns cannot express {0,31}, so bound the length separately.
	return #tag <= portfile.MAX_TAG_LENGTH and tag:match("^[a-z][a-z0-9-]*$") ~= nil
end

---@param tags any
---@return string[]?
---@return string? err
function portfile.normalizeTags(tags)
	if tags == nil then return nil, nil end
	if type(tags) ~= "table" then
		return nil, "tags must be a list of strings"
	end

	local seen = {}
	local normalized = {}
	for _, tag in ipairs(tags) do
		if type(tag) ~= "string" then
			return nil, "tags must be a list of strings"
		end
		tag = tag:lower():gsub("^%s+", ""):gsub("%s+$", "")
		if tag ~= "" then
			if not isValidTag(tag) then
				return nil, "Invalid tag '" .. tag .. "'; tags must be lowercase and match "
					.. portfile.TAG_PATTERN
			end
			if not seen[tag] then
				seen[tag] = true
				normalized[#normalized + 1] = tag
			end
		end
	end

	if #normalized > portfile.MAX_TAGS then
		return nil, "At most " .. portfile.MAX_TAGS .. " tags are allowed"
	end

	table.sort(normalized)
	return normalized, nil
end

---@param versions table?
---@return string[]
local function sortedVersionKeys(versions)
	---@type string[]
	local keys = {}
	if type(versions) == "table" then
		for version in pairs(versions) do
			if type(version) == "string" then keys[#keys + 1] = version end
		end
	end
	table.sort(keys, function(a, b)
		local compared = semver.compare(a, b)
		if compared ~= 0 then return compared < 0 end
		return a < b
	end)
	return keys
end

---@param value any
---@return string?
function portfile.versionCommit(value)
	if type(value) == "string" then return value end
	if type(value) == "table" then return value.commit end
	return nil
end

---@param commit string
---@return string
function portfile.shortCommit(commit)
	return commit:sub(1, 7)
end

---@param dependencies any
---@return table?
function portfile.dependenciesFrom(dependencies)
	if type(dependencies) ~= "table" then return nil end

	local names = {}
	for name, dependency in pairs(dependencies) do
		if type(name) == "string" and type(dependency) == "table"
			and type(dependency.version) == "string" and dependency.version ~= "" then
			names[#names + 1] = name
		end
	end
	table.sort(names)

	if #names == 0 then return nil end
	local result = {}
	for _, name in ipairs(names) do
		json.addField(result, name, dependencies[name].version)
	end
	return result
end

---@param a string?
---@param b string?
---@return boolean
local function sameGit(a, b)
	if a == nil or b == nil then return a == b end
	local function normalize(url)
		return (url:gsub("/+$", ""):gsub("%.git$", ""):lower())
	end
	return normalize(a) == normalize(b)
end

---@class lde.github.PortfileInput
---@field name string
---@field version string
---@field commit string? # git commit, nil for archive versions
---@field git string? # source currently being published from
---@field branch string? # source branch currently being published from
---@field archive string? # tarball URL for an archive version
---@field sha256 string? # tarball SHA-256
---@field size integer? # tarball size in bytes
---@field description string?
---@field license string?
---@field authors string[]?
---@field tags string[]? # nil preserves existing tags
---@field dependencies table? # package config dependencies

---@class lde.github.MergeResult
---@field portfile table?
---@field err string?
---@field kind "new"|"unchanged"|"conflict"

--- Build the updated portfile from an existing one (nil for a first publish).
--- Existing version entries are preserved byte-for-byte. A new git version is
--- a bare commit when it inherits the top-level source and has no hash;
--- otherwise it is an object carrying only commit, any changed git/branch
--- fields, and the optional archive hash.
---@param existing table?
---@param input lde.github.PortfileInput
---@return lde.github.MergeResult
function portfile.merge(existing, input)
	local versions = {}
	if type(existing) == "table" and type(existing.versions) == "table" then
		for _, version in ipairs(sortedVersionKeys(existing.versions)) do
			json.addField(versions, version, existing.versions[version])
		end
	end

	local existingEntry = versions[input.version]
	if existingEntry ~= nil then
		local existingArchive = type(existingEntry) == "table" and existingEntry.archive or nil
		if existingArchive or input.archive then
			local same = existingArchive == input.archive
				and (type(existingEntry) == "table" and existingEntry.sha256 or nil) == input.sha256
			if same then
				return { portfile = nil, err = nil, kind = "unchanged" }
			end
			return {
				portfile = nil,
				err = "Version " .. input.version
					.. " is already published with a different archive or SHA-256; bump the version instead.",
				kind = "conflict",
			}
		end

		local existingCommit = portfile.versionCommit(existingEntry)
		local existingHash = type(existingEntry) == "table" and existingEntry.sha256 or nil
		local short = existingCommit and portfile.shortCommit(existingCommit) or "unknown"
		if existingCommit and input.commit and existingCommit:lower() == input.commit:lower()
			and (existingHash == nil or existingHash == input.sha256) then
			return { portfile = nil, err = nil, kind = "unchanged" }
		end
		return {
			portfile = nil,
			err = "Version " .. input.version .. " is already published with commit " .. short
				.. "; bump the version instead.",
			kind = "conflict",
		}
	end

	-- Top-level source stays canonical across updates so older bare-commit
	-- entries keep resolving to the repository they were published from.
	local topGit = type(existing) == "table" and type(existing.git) == "string" and existing.git or input.git
	local topBranch = type(existing) == "table" and existing.branch or input.branch

	local entry
	if input.archive then
		entry = {}
		json.addField(entry, "archive", input.archive)
		json.addField(entry, "sha256", input.sha256)
		if input.size then json.addField(entry, "size", input.size) end
	elseif input.commit then
		local gitChanged = not sameGit(input.git, topGit)
		local branchChanged = (input.branch or nil) ~= (topBranch or nil)
		if not input.sha256 and not gitChanged and not branchChanged then
			entry = input.commit
		else
			entry = {}
			json.addField(entry, "commit", input.commit)
			-- Only the overrides are stored. A version that keeps the
			-- top-level repository and branch carries just commit + sha256.
			if gitChanged and input.git ~= nil then json.addField(entry, "git", input.git) end
			if branchChanged and input.branch ~= nil then json.addField(entry, "branch", input.branch) end
			if input.sha256 then json.addField(entry, "sha256", input.sha256) end
		end
	else
		return { portfile = nil, err = "A version needs a git commit or an archive URL", kind = "conflict" }
	end
	json.addField(versions, input.version, entry)

	local tags = input.tags
	if tags == nil and type(existing) == "table" then
		tags = existing.tags
	end
	local normalizedTags
	if tags ~= nil then
		local err
		normalizedTags, err = portfile.normalizeTags(tags)
		if err then return { portfile = nil, err = err, kind = "new" } end
		if normalizedTags and #normalizedTags == 0 then normalizedTags = nil end
	end

	local dependencies
	if input.dependencies ~= nil then
		dependencies = portfile.dependenciesFrom(input.dependencies)
	elseif type(existing) == "table" then
		dependencies = existing.dependencies
	end

	local description = input.description
	if description == nil and type(existing) == "table" then description = existing.description end
	local license = input.license
	if license == nil and type(existing) == "table" then license = existing.license end
	local authors = input.authors
	if authors == nil and type(existing) == "table" then authors = existing.authors end

	local result = {}
	json.addField(result, "name", input.name)
	if description ~= nil then json.addField(result, "description", description) end
	if license ~= nil then json.addField(result, "license", license) end
	if authors ~= nil then json.addField(result, "authors", authors) end
	if normalizedTags ~= nil then json.addField(result, "tags", normalizedTags) end
	if topGit ~= nil then json.addField(result, "git", topGit) end
	if topBranch ~= nil then json.addField(result, "branch", topBranch) end
	json.addField(result, "versions", versions)
	if type(existing) == "table" and type(existing.revoked) == "table" and #existing.revoked > 0 then
		json.addField(result, "revoked", existing.revoked)
	end
	if dependencies ~= nil then json.addField(result, "dependencies", dependencies) end

	return { portfile = result, err = nil, kind = "new" }
end

return portfile
