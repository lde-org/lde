local http = {}

local process = require("process2")

--- Perform a HTTP GET request
---@param url string
---@return string|nil
---@return string|nil
function http.get(url)
	if not url or type(url) ~= "string" or url == "" then
		return nil, "Invalid URL"
	end

	local code, stdout, stderr = process.exec("curl", { "-sL", url })
	if code ~= 0 then
		return nil, stderr or "Request failed"
	end

	return stdout
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

	local code, stdout, stderr = process.exec("curl", { "-sL", "-X", "POST", "-d", data, url })
	if code ~= 0 then
		return nil, stderr or "Request failed"
	end

	return stdout
end

return http
