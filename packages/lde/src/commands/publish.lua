const ansi = require("ansi")
const curl = require("curl-sys")
const fs = require("fs")
const sha256 = require("lde-core.util.sha256")

const lde = require("lde-core")
const githubPublish = require("lde.github.publish")

const DEFAULT_REGISTRY = "https://github.com/lde-org/registry"

--- Download a tarball and return its SHA-256, size, and local path.
---@param url string
---@return string? hash
---@return integer? size
---@return string? err
local function hashArchive(url)
	local file = os.tmpname()
	local ok, err = curl.download(url, file, { timeout = 120 })
	if not ok then
		fs.delete(file)
		return nil, nil, "Could not download " .. url .. ": " .. (err or "unknown error")
	end
	local content = fs.read(file)
	fs.delete(file)
	if not content then return nil, nil, "Could not read the downloaded archive" end
	return sha256.sumhexa(content), #content, nil
end

---@param args clap.Args
local function publish(args)
	const pkg, err = lde.Package.open()
	if not pkg then
		lde.error.raise(err)
	end ---@cast pkg -nil

	const config = pkg:readConfig()

	-- The registry enforces strict naming rules; fail here instead of letting the bot reject the PR.
	const nameErr = lde.global.validatePackageName(config.name)
	if nameErr then
		lde.error.raise("Cannot publish: " .. nameErr)
	end

	const globalConfig = lde.global.getConfig()
	const registryUrl = globalConfig.registry or DEFAULT_REGISTRY
	const apiUrl = globalConfig.github and globalConfig.github.apiUrl or nil
	const dryRun = args:flag("dry-run")

	local archiveUrl = args:option("archive")
	local expectedHash = args:option("sha256")
	if expectedHash then expectedHash = expectedHash:lower() end

	if archiveUrl then
		if archiveUrl:match("^https?://") == nil then
			lde.error.raise("--archive must be an http(s) URL")
		end
		if expectedHash and (#expectedHash ~= 64 or expectedHash:match("^[0-9a-f]+$") == nil) then
			lde.error.raise("--sha256 must be a 64-character lowercase SHA-256")
		end

		const hash, size, hashErr = hashArchive(archiveUrl)
		if not hash then
			lde.error.raise(hashErr or "Could not hash the archive")
		end ---@cast hash string
		if expectedHash and expectedHash ~= hash then
			lde.error.raise("SHA-256 mismatch: expected " .. expectedHash .. ", got " .. hash)
		end

		const result, publishErr = githubPublish.run({
			name = config.name,
			version = config.version,
			archive = archiveUrl,
			sha256 = hash,
			size = size,
			config = config,
			registryUrl = registryUrl,
			apiUrl = apiUrl,
			dryRun = dryRun,
			emit = function(message)
				ansi.printf("%s", message)
			end,
		})
		if not result then
			lde.error.raise(publishErr or "Publish failed")
		end
		return
	end

	if expectedHash then
		lde.error.raise("--sha256 is only valid with --archive")
	end

	const pkgDir = pkg:getDir()
	const repo, repoErr = lde.global.openEnclosingRepo(pkgDir)
	if not repo then
		lde.error.raise("Could not find a git repository for this package: "
			.. (repoErr or "unknown error")
			.. ". Pass --archive <url> to publish a tarball instead.")
	end ---@cast repo -nil

	const gitUrl = repo:remoteUrl("origin")
	if not gitUrl then
		lde.error.raise("Could not get git remote URL. Is this a git repo with an 'origin' remote?")
	end ---@cast gitUrl -nil

	const commit = repo:revparse("HEAD")
	if not commit then
		lde.error.raise("Could not get current commit. Does this repo have any commits?")
	end

	const branch = repo:currentBranch() or "master"

	-- Pin the exact archive a client will download. Unrecognized hosts have no
	-- archive endpoint; those clients clone and let git verify the commit.
	local archiveHash
	const tarballUrl = lde.global.gitTarballUrl(githubPublish.toHttpsUrl(gitUrl), commit)
	if tarballUrl then
		const hash, _, hashErr = hashArchive(tarballUrl)
		if not hash then
			lde.error.raise("Could not hash the git archive " .. tarballUrl .. ": "
				.. (hashErr or "unknown error"))
		end ---@cast hash string
		archiveHash = hash
	end

	const result, publishErr = githubPublish.run({
		name = config.name,
		version = config.version,
		commit = commit,
		gitUrl = gitUrl,
		branch = branch,
		sha256 = archiveHash,
		config = config,
		registryUrl = registryUrl,
		apiUrl = apiUrl,
		dryRun = dryRun,
		emit = function(message)
			ansi.printf("%s", message)
		end,
	})

	if not result then
		lde.error.raise(publishErr or "Publish failed")
	end
end

return publish
