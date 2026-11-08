-- GitHub OAuth/API transport used by the device flow.

const json = require("json")

local http = {}

---@param value string
---@return string
local function urlEncode(value)
	return (value:gsub("([^%w%-_%.~])", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

---@param fields table<string, string>
---@return string
local function formEncode(fields)
	local parts = {}
	for key, value in pairs(fields) do
		parts[#parts + 1] = urlEncode(key) .. "=" .. urlEncode(value)
	end
	table.sort(parts)
	return table.concat(parts, "&")
end

---@param body string?
---@return table?
local function decodeBody(body)
	if not body or body == "" then return nil end
	local ok, value = pcall(json.decode, body)
	if ok and type(value) == "table" then return value end

	-- Fall back to form encoding when a proxy ignores Accept: application/json.
	---@cast body string
	local fields = {}
	for key, value in body:gmatch("([^&=]+)=([^&]*)") do
		---@cast key string
		---@cast value string
		value = value:gsub("%+", " "):gsub("%%(%x%x)", function(hex)
			return string.char(tonumber(hex, 16) or 0)
		end)
		fields[key] = value
	end
	return next(fields) and fields or nil
end

---@param response table?
---@param status integer
---@return string
function http.responseError(response, status)
	if type(response) == "table" then
		if type(response.error_description) == "string" and response.error_description ~= "" then
			return response.error_description
		end
		if type(response.error) == "string" and response.error ~= "" then
			return response.error
		end
		if type(response.message) == "string" and response.message ~= "" then
			return response.message
		end
	end
	return "GitHub returned HTTP " .. tostring(status)
end

---@param value any
---@return number?
function http.asNumber(value)
	if type(value) == "number" then return value end
	if type(value) == "string" then return tonumber(value) end
	return nil
end

---@class lde.github.AuthHttpOpts
---@field http fun(opts: table): (table?, string?)
---@field userAgent string
---@field apiUrl string

---@param opts lde.github.AuthHttpOpts
---@return table
function http.new(opts)
	local instance = {
		responseError = http.responseError,
		asNumber = http.asNumber,
	}

	---@param url string
	---@param fields table<string, string>
	---@return table?, integer, string?
	function instance.postForm(url, fields)
		local res, transportErr = opts.http({
			url = url,
			method = "POST",
			headers = {
				["Accept"] = "application/json",
				["Content-Type"] = "application/x-www-form-urlencoded",
				["User-Agent"] = opts.userAgent,
			},
			body = formEncode(fields),
			timeout = 30,
		})
		if not res then
			return nil, 0, transportErr or ("request to " .. url .. " failed")
		end

		local status = res.status or 0
		local data = decodeBody(res.body)
		if status < 200 or status >= 300 then
			return data, status, http.responseError(data, status)
		end
		return data, status, nil
	end

	---@param session lde.github.AuthSession
	---@return table?, string?
	function instance.fetchUser(session)
		local res, transportErr = opts.http({
			url = opts.apiUrl .. "/user",
			method = "GET",
			headers = {
				["Accept"] = "application/vnd.github+json",
				["Authorization"] = "Bearer " .. session.accessToken,
				["User-Agent"] = opts.userAgent,
				["X-GitHub-Api-Version"] = "2022-11-28",
			},
			timeout = 30,
		})
		if not res then
			return nil, transportErr or "GitHub user request failed"
		end

		local data = decodeBody(res.body)
		if (res.status or 0) >= 400 then
			return nil, http.responseError(data, res.status or 0)
		end
		if type(data) ~= "table" then
			return nil, "GitHub returned a malformed user response"
		end
		return data, nil
	end

	return instance
end

return http
