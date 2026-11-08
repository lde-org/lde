-- GitHub REST helper. All responses are decoded JSON; transport failures and
-- non-2xx statuses come back as an error message while the status stays
-- available so callers can treat 404 as "not found".
const json = require("json")

---@class lde.github.ApiResponse
---@field status integer
---@field data table?
---@field body string?

---@class lde.github.ApiOptions
---@field baseUrl string? # defaults to https://api.github.com
---@field token string? # bearer token sent when present
---@field http (fun(opts: curl.CurlOptions): (curl.CurlResponse?, string?))? # injectable transport
---@field userAgent string?
---@field onUnauthorized (fun(): (string?, string?))? # refresh hook; called once on 401

local api = {}

---@return string
local function defaultUserAgent()
	local ok, version = pcall(require, "lde.version")
	return "lde/" .. (ok and tostring(version) or "0.11.0")
end

---@param opts curl.CurlOptions
---@return curl.CurlResponse?, string?
local function defaultHttp(opts)
	return require("curl-sys").request(opts)
end

---@param body string?
---@return table?
local function decode(body)
	if not body or body == "" then return nil end
	local ok, value = pcall(json.decode, body)
	if not ok then return nil end
	return type(value) == "table" and value or nil
end

---@param data table?
---@param status integer
---@return string
local function messageFor(data, status)
	if type(data) == "table" and type(data.message) == "string" and data.message ~= "" then
		return data.message
	end
	return "GitHub returned HTTP " .. tostring(status)
end

---@class lde.github.Api
---@field request fun(method: string, path: string, body: table?, opts?: table?): (table?, integer, string?)
---@field fetchRaw fun(url: string, opts?: table?): (string?, integer, string?)
---@field setToken fun(token: string?)

---@param opts lde.github.ApiOptions?
---@return lde.github.Api
function api.new(opts)
	opts = opts or {}
	local baseUrl = (opts.baseUrl or "https://api.github.com"):gsub("/+$", "")
	local http = opts.http or defaultHttp
	local userAgent = opts.userAgent or defaultUserAgent()
	local token = opts.token
	local onUnauthorized = opts.onUnauthorized

	---@param pathOrUrl string
	---@return string
	local function absolute(pathOrUrl)
		if pathOrUrl:match("^https?://") then return pathOrUrl end
		if pathOrUrl:sub(1, 1) ~= "/" then pathOrUrl = "/" .. pathOrUrl end
		return baseUrl .. pathOrUrl
	end

	---@param method string
	---@param path string
	---@param body table?
	---@param requestOpts table?
	---@return table?, integer, string?
	local function send(method, path, body, requestOpts)
		local useToken = requestOpts and requestOpts.token
		if useToken == nil then useToken = token end

		local headers = {
			["Accept"] = "application/vnd.github+json",
			["User-Agent"] = userAgent,
			["X-GitHub-Api-Version"] = "2022-11-28",
		}
		if useToken then
			headers["Authorization"] = "Bearer " .. useToken
		end

		local encoded
		if body ~= nil then
			headers["Content-Type"] = "application/json"
			encoded = json.encode(body)
		end

		local res, transportErr = http({
			url = absolute(path),
			method = method,
			headers = headers,
			body = encoded,
			timeout = (requestOpts and requestOpts.timeout) or 30,
		})
		if not res then
			return nil, 0, transportErr or ("request to " .. path .. " failed")
		end

		local status = res.status or 0
		local data = decode(res.body)
		if status >= 200 and status < 300 then
			return data, status, nil
		end
		return data, status, messageFor(data, status)
	end

	---@param method string
	---@param path string
	---@param body table?
	---@param requestOpts table?
	---@return table?, integer, string?
	local function request(method, path, body, requestOpts)
		requestOpts = requestOpts or {}
		local data, status, err = send(method, path, body, requestOpts)
		if status == 401 and onUnauthorized and not requestOpts.retried then
			local fresh, refreshErr = onUnauthorized()
			if fresh then
				local retryOpts = {}
				for k, v in pairs(requestOpts) do retryOpts[k] = v end
				retryOpts.token = fresh
				retryOpts.retried = true
				token = fresh
				return send(method, path, body, retryOpts)
			end
			if refreshErr then
				return data, status, refreshErr
			end
		end
		return data, status, err
	end

	--- Raw fetch with no versioned API headers, for raw.githubusercontent.com.
	---@param url string
	---@param requestOpts table?
	---@return string?, integer, string?
	local function fetchRaw(url, requestOpts)
		requestOpts = requestOpts or {}
		local res, transportErr = http({
			url = url,
			method = "GET",
			headers = {
				["Accept"] = "*/*",
				["User-Agent"] = userAgent,
			},
			timeout = requestOpts.timeout or 30,
		})
		if not res then
			return nil, 0, transportErr or ("request to " .. url .. " failed")
		end
		local status = res.status or 0
		if status == 404 then return nil, 404, nil end
		if status ~= 200 then
			return nil, status, "HTTP " .. tostring(status)
		end
		return res.body or "", status, nil
	end

	---@param freshToken string?
	local function setToken(freshToken)
		token = freshToken
	end

	return {
		request = request,
		fetchRaw = fetchRaw,
		setToken = setToken,
	}
end

return api
