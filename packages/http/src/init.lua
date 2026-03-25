local http = {}

local process = require("process")

--- Perform a HTTP GET request
---@param url string
---@return string|nil
---@return string|nil
function http.get(url)
	if not url or type(url) ~= "string" or url == "" then
		return nil, "Invalid URL"
	end

	local ok, out = process.exec("curl", { "-sL", url }, { maxOutputChunks = math.huge })
	if not ok then
		return nil, out or "Request failed"
	end

	return out
end

--- Perform a HTTP POST request
---@param url string
---@param data string
---@return string|nil
---@return string|nil
function http.post(url, data)
	if not url or type(url) ~= "string" or url == "" then
		return nil, "Invalid URL"
	end

	if not data or type(data) ~= "string" then
		return nil, "Invalid data"
	end

	local ok, out = process.exec("curl", { "-sL", "-X", "POST", "-d", data, url })
	if not ok then
		return nil, out or "Request failed"
	end

	return out
end

return http
