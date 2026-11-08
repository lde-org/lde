-- Programmatic publishing: reads the registry state, checks ownership, builds
-- the portfile, then creates a branch/commit/pull request through the GitHub
-- Data API. Pure helpers, fork readiness and remote writes live in sibling
-- modules; this file is the orchestration.

const json = require("json")

const apiModule = require("lde.github.api")
const authModule = require("lde.github.auth")
const portfileModule = require("lde.github.portfile")
const fork = require("lde.github.publish.fork")
const plan = require("lde.github.publish.plan")
const remote = require("lde.github.publish.remote")

local publish = {}

publish.toHttpsUrl = plan.toHttpsUrl
publish.parseRepo = plan.parseRepo
publish.packagePath = plan.packagePath
publish.contentsPath = plan.contentsPath
publish.preflight = plan.preflight
publish.branchName = plan.branchName
publish.prBody = plan.prBody

---@class lde.github.PublishRunOpts
---@field name string
---@field version string
---@field commit string?
---@field gitUrl string?
---@field archive string?
---@field sha256 string?
---@field size integer?
---@field branch string?
---@field config lde.Package.Config
---@field registryUrl string
---@field apiUrl string?
---@field dryRun boolean?
---@field auth table? # auth instance (tests)
---@field api table? # api instance (tests)
---@field sleep (fun(ms: number))? # fork-readiness wait (tests)
---@field emit (fun(message: string))?

---@class lde.github.PublishResult
---@field portfile table?
---@field branch string?
---@field pullRequest table?
---@field unchanged boolean?
---@field dryRun boolean?

--- Run the publish flow. Returns nil + a concise error message on failure.
---@param opts lde.github.PublishRunOpts
---@return lde.github.PublishResult?
---@return string? err
function publish.run(opts)
	local emit = opts.emit or function(message) print(message) end
	local isDryRun = opts.dryRun == true
	if opts.sha256 and (#opts.sha256 ~= 64 or opts.sha256:match("^[0-9a-f]+$") == nil) then
		return nil, "SHA-256 must be 64 lowercase hexadecimal characters"
	end
	if opts.archive then
		if not opts.sha256 then
			return nil, "Archive publishing requires a SHA-256"
		end
	elseif not opts.commit then
		return nil, "Git publishing requires a commit"
	end

	local sleep = opts.sleep or function(ms)
		require("lde-core.util.childpool").sleep(ms)
	end
	local authImpl = opts.auth or authModule
	local owner, repository, repoErr = plan.parseRepo(opts.registryUrl)
	if not owner then return nil, repoErr end
	---@cast owner -nil
	---@cast repository -nil

	local registryRepo = "/repos/" .. owner .. "/" .. repository

	-- Auth is optional for a dry run: it only gates ownership/admin checks.
	local session
	if isDryRun then
		local loadErr
		session, loadErr = authImpl.load()
		if loadErr then session = nil end
	else
		local authErr
		session, authErr = authImpl.ensureValid()
		if not session then return nil, authErr end
		---@cast session -nil
	end

	local api = opts.api
	if not api then
		api = apiModule.new({
			baseUrl = opts.apiUrl,
			token = session and session.accessToken,
			onUnauthorized = function()
				if isDryRun or not session then return nil end
				local refreshed, refreshErr = authImpl.refresh(session)
				if refreshed then
					session = refreshed
					return refreshed.accessToken
				end
				return nil, refreshErr
			end,
		})
	else
		api.setToken(session and session.accessToken)
	end

	local repoInfo, repoStatus, repoInfoErr = api.request("GET", registryRepo)
	if repoStatus == 401 and isDryRun then
		-- A dry run may start without a usable session; retry anonymously so
		-- the preview still works for public registries.
		session = nil
		api.setToken(nil)
		repoInfo, repoStatus, repoInfoErr = api.request("GET", registryRepo, nil, {
			token = false,
			retried = true,
		})
	end
	if repoStatus == 401 then
		return nil, "GitHub authentication failed"
			.. (repoInfoErr and (": " .. repoInfoErr) or "") .. "; run `lde login` again."
	end
	if repoStatus == 404 then
		return nil, "Registry repository not found: " .. owner .. "/" .. repository
	end

	local baseBranch = "master"
	local isAdmin = false
	if type(repoInfo) == "table" then
		if type(repoInfo.default_branch) == "string" and repoInfo.default_branch ~= "" then
			baseBranch = repoInfo.default_branch
		end
		isAdmin = type(repoInfo.permissions) == "table"
			and (repoInfo.permissions.admin == true or repoInfo.permissions.push == true)
	end

	local existing, portfileStatus, portfileErr = plan.fetchJson(api,
		plan.contentsPath(owner, repository, baseBranch, plan.packagePath(opts.name)))
	if portfileErr then return nil, portfileErr end
	if portfileStatus ~= 404 and existing == nil then
		return nil, "Could not read the registry portfile for " .. opts.name
	end

	local authority, authorityStatus, authorityErr = plan.fetchJson(api,
		plan.contentsPath(owner, repository, baseBranch, "authority.json"))
	if authorityErr then return nil, authorityErr end
	if authorityStatus ~= 404 and authority == nil then
		authority = {}
	end

	local check = plan.preflight({
		name = opts.name,
		existing = existing,
		authority = authority or {},
		userId = type(session) == "table" and plan.asNumber(session.id) or nil,
		isAdmin = isAdmin,
	})
	if check.blocked then return nil, check.message end
	emit(check.message)
	if check.note then emit(check.note) end

	local merge = portfileModule.merge(existing, {
		name = opts.name,
		version = opts.version,
		commit = opts.commit,
		git = opts.gitUrl and plan.toHttpsUrl(opts.gitUrl) or nil,
		branch = opts.branch,
		archive = opts.archive,
		sha256 = opts.sha256,
		size = opts.size,
		description = opts.config.description,
		license = opts.config.license,
		authors = opts.config.authors,
		tags = opts.config.tags,
		dependencies = opts.config.dependencies,
	})

	if merge.kind == "unchanged" then
		local entry = existing and existing.versions and existing.versions[opts.version]
		if opts.archive then
			emit("Version " .. opts.version .. " is already published with the same archive hash; nothing to do.")
		else
			local short = portfileModule.versionCommit(entry)
			emit("Version " .. opts.version .. " is already published with commit "
				.. (short and portfileModule.shortCommit(short) or "unknown") .. "; nothing to do.")
		end
		return { unchanged = true, portfile = existing, dryRun = isDryRun }
	end
	if not merge.portfile then
		return nil, merge.err or "Could not build the registry portfile"
	end

	local portfile = merge.portfile
	local title = "Publish " .. opts.name .. "@" .. opts.version
	local branch = plan.branchName(opts.name, opts.version, opts.commit or opts.sha256 or "source")

	if isDryRun then
		local encoded = json.encode(portfile):gsub("\n$", "")
		emit(encoded)
		emit("Pull request: " .. title)
		return { portfile = portfile, branch = branch, dryRun = true }
	end

	local headRepo = registryRepo
	local headOwner = owner
	local canPush = type(repoInfo) == "table"
		and type(repoInfo.permissions) == "table"
		and repoInfo.permissions.push == true
	if not canPush then
		local forkFullName, forkOwner, forkErr =
			fork.ensureFork(api, owner, repository, baseBranch, sleep)
		if not forkFullName then return nil, forkErr end
		headRepo = "/repos/" .. forkFullName
		headOwner = forkOwner
		emit("Forked the registry as " .. forkFullName .. ".")
	end

	local pullRequest, remoteErr, finalBranch = remote.create(api, {
		registryRepo = registryRepo,
		headRepo = headRepo,
		headOwner = headOwner,
		owner = owner,
		baseBranch = baseBranch,
		branch = branch,
		title = title,
		body = plan.prBody({
			name = opts.name,
			version = opts.version,
			commit = opts.commit,
			git = opts.gitUrl and plan.toHttpsUrl(opts.gitUrl) or nil,
			archive = opts.archive,
			sha256 = opts.sha256,
			branch = opts.branch,
			login = type(session) == "table" and session.login or nil,
			id = type(session) == "table" and plan.asNumber(session.id) or nil,
			tags = type(merge.portfile.tags) == "table" and merge.portfile.tags or nil,
		}),
		portfilePath = plan.packagePath(opts.name),
		portfile = portfile,
	})
	if not pullRequest then return nil, remoteErr end

	local url = pullRequest.html_url
	emit("Opened pull request " .. (type(url) == "string" and url or ("#" .. tostring(pullRequest.number or "?"))))

	return {
		portfile = portfile,
		branch = finalBranch or branch,
		pullRequest = pullRequest,
		dryRun = false,
	}
end

return publish
