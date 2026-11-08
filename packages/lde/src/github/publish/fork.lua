-- Fork readiness for contributors without write access to the registry.

local fork = {}

--- Fork the registry when the user cannot push upstream. GitHub returns 202
--- while the fork is being created, so poll the fork's base ref before use.
---@param api table
---@param owner string
---@param repository string
---@param baseBranch string
---@param sleep fun(ms: number)
---@return string? forkFullName
---@return string? forkOwner
---@return string? err
function fork.ensureFork(api, owner, repository, baseBranch, sleep)
	local info, status, err = api.request("POST",
		"/repos/" .. owner .. "/" .. repository .. "/forks", { default_branch_only = true })
	status = tonumber(status) or 0
	if status < 200 or status >= 300
		or type(info) ~= "table" or type(info.full_name) ~= "string" then
		return nil, nil, "Could not fork the registry: " .. (err or "unexpected response")
	end

	local ownerName = type(info.owner) == "table" and info.owner.login or nil
	ownerName = ownerName or info.full_name:match("^([^/]+)/")
	if not ownerName then
		return nil, nil, "Could not determine the fork owner"
	end

	-- Keep the fork current; a no-op merge-upstream is fine.
	api.request("POST", "/repos/" .. info.full_name .. "/merge-upstream", { branch = baseBranch })

	for _ = 1, 10 do
		local ref, refStatus = api.request("GET",
			"/repos/" .. info.full_name .. "/git/ref/heads/" .. baseBranch)
		if refStatus == 200 and type(ref) == "table" then
			return info.full_name, ownerName, nil
		end
		sleep(1000)
	end

	return nil, nil, "Fork created but its base branch is not ready yet; try again in a moment."
end

return fork
