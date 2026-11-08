-- GitHub Git Data API writes for publishing: branch, blob, tree, commit and
-- pull request. The caller decides whether the head is upstream or a fork.

const json = require("json")

local remote = {}

---@class lde.github.RemoteOpts
---@field api table
---@field registryRepo string # upstream /repos/owner/name
---@field headRepo string # upstream or fork /repos/owner/name
---@field headOwner string
---@field owner string # upstream owner
---@field baseBranch string
---@field branch string
---@field title string
---@field body string
---@field portfilePath string
---@field portfile table

---@param api table
---@param opts lde.github.RemoteOpts
---@return table? pullRequest
---@return string? err
---@return string? branch
function remote.create(api, opts)
	local branch = opts.branch
	local ref, refStatus, refErr = api.request("GET",
		opts.headRepo .. "/git/ref/heads/" .. opts.baseBranch)
	if refErr or refStatus ~= 200 or type(ref) ~= "table" or type(ref.object) ~= "table"
		or type(ref.object.sha) ~= "string" then
		return nil, "Could not read the base branch '" .. opts.baseBranch .. "': "
			.. (refErr or "unexpected response")
	end

	local blob, _, blobErr = api.request("POST", opts.headRepo .. "/git/blobs", {
		content = json.encode(opts.portfile),
		encoding = "utf-8",
	})
	if blobErr or type(blob) ~= "table" or type(blob.sha) ~= "string" then
		return nil, "Could not create the portfile blob: " .. (blobErr or "unexpected response")
	end

	local baseCommit, _, baseCommitErr = api.request("GET",
		opts.headRepo .. "/git/commits/" .. ref.object.sha)
	if baseCommitErr or type(baseCommit) ~= "table" or type(baseCommit.tree) ~= "table"
		or type(baseCommit.tree.sha) ~= "string" then
		return nil, "Could not read the base commit: " .. (baseCommitErr or "unexpected response")
	end

	local newTree, _, treeErr = api.request("POST", opts.headRepo .. "/git/trees", {
		base_tree = baseCommit.tree.sha,
		tree = {
			{
				path = opts.portfilePath,
				mode = "100644",
				type = "blob",
				sha = blob.sha,
			},
		},
	})
	if treeErr or type(newTree) ~= "table" or type(newTree.sha) ~= "string" then
		return nil, "Could not create the registry tree: " .. (treeErr or "unexpected response")
	end

	local newCommit, _, commitErr = api.request("POST", opts.headRepo .. "/git/commits", {
		message = opts.title,
		tree = newTree.sha,
		parents = { ref.object.sha },
	})
	if commitErr or type(newCommit) ~= "table" or type(newCommit.sha) ~= "string" then
		return nil, "Could not create the publish commit: " .. (commitErr or "unexpected response")
	end

	local _, createRefStatus, createRefErr = api.request("POST", opts.headRepo .. "/git/refs", {
		ref = "refs/heads/" .. branch,
		sha = newCommit.sha,
	})
	if createRefStatus == 422 then
		local message = (createRefErr or ""):lower()
		if not message:find("already exists", 1, true) then
			return nil, "Could not create the publish branch: " .. (createRefErr or "HTTP 422")
		end
		local stamp = os.time()
		local created = false
		for attempt = 1, 5 do
			local candidate = branch .. "-" .. tostring(stamp) .. (attempt > 1 and ("-" .. attempt) or "")
			local _, retryStatus, retryErr = api.request("POST", opts.headRepo .. "/git/refs", {
				ref = "refs/heads/" .. candidate,
				sha = newCommit.sha,
			})
			if retryStatus ~= 422 then
				branch = candidate
				created = retryStatus and retryStatus >= 200 and retryStatus < 300
				if not created then
					return nil, "Could not create the publish branch: " .. (retryErr or "unexpected response")
				end
				break
			end
		end
		if not created then
			return nil, "Could not create the publish branch: " .. (createRefErr or "branch already exists")
		end
	elseif createRefErr then
		return nil, "Could not create the publish branch: " .. createRefErr
	end

	local pullRequest, _, prErr = api.request("POST", opts.registryRepo .. "/pulls", {
		title = opts.title,
		head = opts.headOwner == opts.owner and branch or (opts.headOwner .. ":" .. branch),
		base = opts.baseBranch,
		body = opts.body,
	})
	if prErr or type(pullRequest) ~= "table" then
		return nil, "Could not open the pull request: " .. (prErr or "unexpected response")
	end
	return pullRequest, nil, branch
end

return remote
