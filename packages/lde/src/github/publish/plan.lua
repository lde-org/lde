-- Pure publishing helpers: registry URL parsing, ownership preflight,
-- branch/PR metadata and raw registry reads. No GitHub mutations live here.

const json = require("json")

const portfileModule = require("lde.github.portfile")

local plan = {}

---@param url string
---@return string
function plan.toHttpsUrl(url)
	local host, path = url:match("^git@([^:]+):(.+)$")
	if host and path then
		return "https://" .. host .. "/" .. path
	end
	local protoHost, protoPath = url:match("^ssh://git@([^/]+)/(.+)$")
	if protoHost and protoPath then
		return "https://" .. protoHost .. "/" .. protoPath
	end
	return url
end

--- Derive owner/repo from the registry URL. Only GitHub forms are accepted.
---@param url string
---@return string? owner
---@return string? repository
---@return string? err
function plan.parseRepo(url)
	if type(url) ~= "string" or url == "" then
		return nil, nil, "Registry URL is not configured"
	end

	local cleaned = url:gsub("%s+$", ""):gsub("/+$", "")
	local owner, repository = cleaned:match("^https?://github%.com/([^/]+)/([^/]+)$")

	if not owner then
		local host, path = cleaned:match("^git@([^:]+):(.+)$")
		if host == "github.com" then
			owner, repository = path:match("^([^/]+)/([^/]+)$")
		end
	end
	if not owner then
		local host, path = cleaned:match("^ssh://git@([^/]+)/(.+)$")
		if host == "github.com" then
			owner, repository = path:match("^([^/]+)/([^/]+)$")
		end
	end

	if not owner then
		return nil, nil, "Registry is not a GitHub repository: " .. url
	end

	repository = repository:gsub("%.git$", "")
	if owner == "" or repository == "" then
		return nil, nil, "Registry is not a GitHub repository: " .. url
	end
	return owner, repository, nil
end

---@param name string
---@return string
function plan.packagePath(name)
	return "packages/" .. name .. ".json"
end

---@param owner string
---@param repository string
---@param branch string
---@param filePath string
---@return string
function plan.rawUrl(owner, repository, branch, filePath)
	return "https://raw.githubusercontent.com/" .. owner .. "/" .. repository .. "/"
		.. branch .. "/" .. filePath
end

---@param value any
---@return number?
function plan.asNumber(value)
	if type(value) == "number" then return value end
	if type(value) == "string" then return tonumber(value) end
	return nil
end

---@param list any
---@param id any
---@return boolean
local function contains(list, id)
	if type(list) ~= "table" or id == nil then return false end
	for _, entry in ipairs(list) do
		if tostring(entry) == tostring(id) then return true end
	end
	return false
end

---@class lde.github.PreflightOpts
---@field name string
---@field existing table? # current portfile, nil for a first publish
---@field authority table?
---@field userId number?
---@field isAdmin boolean?

---@class lde.github.Preflight
---@field message string
---@field note string?
---@field blocked boolean?
---@field kind "new"|"owner"|"admin"|"unverified"

--- Decide whether the current user may publish this name.
---@param opts lde.github.PreflightOpts
---@return lde.github.Preflight
function plan.preflight(opts)
	local name = opts.name
	local existing = opts.existing
	local authority = opts.authority or {}
	local namespace = name:match("^(.-)/")

	if not existing then
		local note
		if namespace then
			local namespaceOwners = type(authority.namespaces) == "table"
				and authority.namespaces[namespace] or nil
			if namespaceOwners and opts.userId ~= nil and not contains(namespaceOwners, opts.userId) then
				return {
					blocked = true,
					kind = "new",
					message = "You do not own the '" .. namespace .. "' namespace; only its owner can publish '"
						.. name .. "'.",
				}
			end
			if not namespaceOwners then
				note = "Namespace " .. namespace
					.. " is not claimed yet; a moderator will create it when this package is approved."
			end
		end
		return {
			kind = "new",
			message = "First publish of " .. name
				.. ". A moderator must approve this pull request before it goes live.",
			note = note,
		}
	end

	if opts.userId == nil then
		return {
			kind = "unverified",
			message = "Ownership could not be verified without a GitHub login; run `lde login` to check.",
		}
	end

	local owners = {}
	local top = type(authority.top) == "table" and authority.top[name] or nil
	if type(top) == "table" then
		for _, id in ipairs(top) do owners[#owners + 1] = id end
	end
	if namespace and type(authority.namespaces) == "table" then
		local namespaceOwners = authority.namespaces[namespace]
		if type(namespaceOwners) == "table" then
			for _, id in ipairs(namespaceOwners) do owners[#owners + 1] = id end
		end
	end

	if contains(owners, opts.userId) then
		return {
			kind = "owner",
			message = "You own " .. name .. ". This update will be auto-approved and merged.",
		}
	end
	if opts.isAdmin then
		return {
			kind = "admin",
			message = "Repository maintainer. This update will be auto-approved and merged.",
		}
	end

	return {
		blocked = true,
		kind = "unverified",
		message = "You do not own " .. name
			.. "; only its owner or a repository admin can update it.",
	}
end

---@param name string
---@return string
local function safeSegment(name)
	return (name:gsub("[/\\]", "-"):gsub("[^%w%-%._]", "-"):gsub("%-+", "-"))
end

---@param name string
---@param version string
---@param identifier string # commit or archive hash
---@return string
function plan.branchName(name, version, identifier)
	return "publish/" .. safeSegment(name) .. "/" .. safeSegment(version)
		.. "-" .. portfileModule.shortCommit(identifier)
end

---@class lde.github.PrInfo
---@field name string
---@field version string
---@field commit string?
---@field git string?
---@field archive string?
---@field sha256 string?
---@field branch string?
---@field login string?
---@field id number?
---@field tags string[]?

---@param info lde.github.PrInfo
---@return string
function plan.prBody(info)
	local lines = {
		"<!-- lde-publish -->",
		"Publish `" .. info.name .. "@" .. info.version .. "`.",
		"",
		"- Package: `" .. info.name .. "`",
		"- Version: `" .. info.version .. "`",
	}
	if info.archive then
		lines[#lines + 1] = "- Archive: `" .. info.archive .. "`"
		lines[#lines + 1] = "- SHA-256: `" .. (info.sha256 or "") .. "`"
	else
		lines[#lines + 1] = "- Commit: `" .. (info.commit or "") .. "`"
		lines[#lines + 1] = "- Source: `" .. (info.git or "") .. "`"
			.. (info.branch and (" (branch `" .. info.branch .. "`)") or "")
		if info.sha256 then
			lines[#lines + 1] = "- SHA-256: `" .. info.sha256 .. "`"
		end
	end
	if info.login then
		lines[#lines + 1] = "- Author: @" .. info.login
			.. (info.id and (" (id " .. tostring(info.id) .. ")") or "")
	else
		lines[#lines + 1] = "- Author: unknown"
	end
	if info.tags and #info.tags > 0 then
		lines[#lines + 1] = "- Tags: " .. table.concat(info.tags, ", ")
	end
	return table.concat(lines, "\n") .. "\n"
end

---@param api table
---@param url string
---@return table?
---@return integer
---@return string? err
function plan.fetchJson(api, url)
	local body, status, err = api.fetchRaw(url)
	if status == 404 then return nil, 404, nil end
	if err then return nil, status, "Could not read " .. url .. ": " .. err end

	local ok, decoded = pcall(json.decode, body or "")
	if not ok or type(decoded) ~= "table" then
		return nil, status, "Malformed JSON from " .. url
	end
	return decoded, status, nil
end

return plan
