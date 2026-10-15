--- Dependency resolution: turns a manifest's dependency entries into a
--- resolved, materialized graph of "nodes". Owns the two-phase walk
--- (metadata first, content after), the per-kind behavior
--- (path/git/archive/luarocks), and conflict detection; the node model
--- (types, constructors, source identity) lives in node.lua.

const fs = require("fs")
const rocked = require("rocked")
const md5 = require("lde-core.util.md5")
local download = require("lde-core.util.download")

local features = require("lde-core.package.features")

local lde = require("lde-core")

-- Dependency-node model: type declarations, node constructors, and the
-- source-identity helpers used to detect conflicts and apply lockfile pins.
local nodeModel = require("lde-core.package.install.node")
local withConfigFlags = nodeModel.withConfigFlags
local enabledOptional = nodeModel.enabledOptional
local sourceKey = nodeModel.sourceKey
local depSourceKey = nodeModel.depSourceKey
local applyLock = nodeModel.applyLock
local makeNode = nodeModel.makeNode

-- ── Per-kind behavior ─────────────────────────────────────────────────────

--- rockspec `source.md5` covers the archive its `source.url` points at; LuaRocks
--- checks it before unpacking, and a mismatch must not stay in the download cache.
---@param n lde.install.Node
---@param c lde.install.ContentPlan
local function verifyMd5(n, c)
	const source = n.spec?.source
	const expected = source?.md5
	if not expected or expected == "" then return end
	-- `source.md5` covers the artifact at `source.url`, not the .src.rock (which
	-- carries the already-published tree) nor a git tarball.
	if c.kind ~= "archive" or c.url ~= source?.url then return end
	const content = fs.read(c.file --[[@as string]])
	if content and md5.sumhexa(content) ~= expected:lower() then
		download.invalidate(c.file --[[@as string]])
		lde.error.raise("MD5 check for " .. (c.url or c.file or "?") .. " has failed.")
	end
end

--- The package directory inside a content plan: the source dir (source.dir, or the
--- archive's single top-level directory) when the plan extracted a plain archive,
--- else the plan's own directory. Resolved lazily so a plan reused from cache —
--- extraction skipped because the dir was already there — still opens correctly.
---@param n lde.install.Node
---@param c lde.install.ContentPlan
---@return string?
local function packageDirOf(n, c)
	if not c.dir then return nil end
	if c.kind ~= "src" and not c.srcDir then
		const source = n.spec?.source
		c.srcDir = lde.global.sourceDirFor(c.dir, source?.dir, source?.file)
	end
	return c.kind == "src" and c.dir or (c.srcDir or c.dir)
end

---@type table<string, lde.install.Handler>
const handlers = {}

---@param node lde.install.Node
local function h(node)
	return handlers[node.kind]
end

---@param node lde.install.Node
local function content(node)
	return h(node).content(node)
end

--- Make the node's dependency list available (idempotent).
---@param node lde.install.Node
local function consume(node)
	if node.deps then return end
	h(node).consume(node)
end

--- Extract the node's downloaded content (after the batch drained). A failed
--- download or extract is recorded on the node instead of raising, so the
--- rest of the graph keeps downloading/building; failures are reported
--- together at the end of resolution.
---@param node lde.install.Node
local function materialize(node)
	local c = content(node)
	assert(c, "no content plan for '" .. node.alias .. "'")
	local ok, err = pcall(h(node).materialize, node, c)
	if not ok then
		node.error = tostring(err)
	else
		node.isMaterialized = true
		node.error = nil
	end
end

--- Open the node's package (requires content materialized).
---@param node lde.install.Node
local function open(node)
	if node.pkg then return node.pkg end
	h(node).open(node)
	return node.pkg --[[@as lde.Package]]
end

--- Emit the lockfile entry for this node.
---@param node lde.install.Node
local function lock(node)
	return h(node).lock(node)
end

--- Standard consume for content-based kinds: open the package, read its deps.
---@param node lde.install.Node
local function consumeFromPkg(node)
	local pkg = open(node)
	node.deps = pkg:readConfig().dependencies or {}
end

--- Open a node's package, emit its lock entry, and record the stack entry
--- (raising on a source conflict for an alias already registered). Idempotent
--- for already-registered aliases; the conflict check always runs.
---@param node lde.install.Node
---@param ctx lde.install.Context
local function registerNode(node, ctx)
	local pkg = open(node)
	local lockEntry = lock(node)
	lockEntry.name = node.depInfo.name
	const existing = ctx.stack[node.alias]
	if existing then
		local existingKey = sourceKey(existing.lock, existing.pkg)
		local newKey = sourceKey(lockEntry, pkg)
		if existingKey ~= newKey then
			lde.error.raise("Conflicting sources for dependency '" .. node.alias .. "':\n  " .. existingKey .. "\n  " .. newKey)
		end
	else
		-- Flags on for this dependency; the union is kept across aliases so its build script can branch on them like the bundler drops files.
		local flags = features.enabledFlags(features.of(pkg), node.depInfo.features)
		if pkg.features then
			local merged = {}
			for _, flag in ipairs(pkg.features) do merged[flag] = true end
			for _, flag in ipairs(flags) do merged[flag] = true end
			flags = {}
			for flag in pairs(merged) do flags[#flags + 1] = flag end
			table.sort(flags)
		end
		pkg:setFeatures(flags)

		ctx.stack[node.alias] = { pkg = pkg, lock = withConfigFlags(lockEntry, node.depInfo, pkg) }
	end
end

--- Add a batch of deps to the graph, returning the newly created nodes. An
--- alias already in the graph is verified against the new request's source
--- instead of being re-created.
---@param deps table<string, lde.Package.Config.Dependency>
---@param relativeTo string
---@param ctx lde.install.Context
---@param graph table<string, lde.install.Node>
---@param order lde.install.Node[]
---@param parent lde.install.Node? # the package these deps are declared by, nil for the root
local function addDeps(deps, relativeTo, ctx, graph, order, parent)
	-- The declaring package's own optional-dep set (rockspec-backed nodes have none; the root's is the caller's).
	local enabled = ctx.enabledOptional

	if parent then
		enabled = parent.pkg and enabledOptional(parent.pkg, parent.depInfo.features) or {}
	end

	---@type lde.install.Node[]
	const newNodes = {}
	for alias, depInfo in pairs(deps) do
		-- Optional and off everywhere: never materialized, therefore never bundled.
		local wanted = not depInfo.optional or enabled[alias] == true

		if not graph[alias] then
			local node = makeNode(alias, depInfo, relativeTo, ctx)
			node.wanted = wanted
			graph[alias] = node
			order[#order + 1] = node
			newNodes[#newNodes + 1] = node
		else
			-- Wanted by anyone means wanted.
			if wanted then graph[alias].wanted = true end

			-- Same alias requested from another place: the sources must match (e.g. two path deps under one name).
			local effective = applyLock(ctx, alias, depInfo)
			local existingKey = graph[alias].sourceKey
			local newKey = depSourceKey(alias, effective, relativeTo)
			if existingKey ~= newKey then
				lde.error.raise("Conflicting sources for dependency '" .. alias .. "':\n  " .. existingKey .. "\n  " .. newKey)
			end
		end
	end
	return newNodes
end

--- path: local directory, already on disk.
handlers.path = {
	content = || -> nil,
	materialize = function() end,
	---@param n lde.install.Node
	open = function(n)
		local pkg, err = lde.Package.open(n.dir, n.depInfo.rockspec)
		if not pkg then
			lde.error.raise("Failed to load local dependency package for: " .. n.alias .. "\nError: " .. err)
		end ---@cast pkg -nil
		n.pkg = pkg
		n.expandDir = pkg:getDir()
	end,
	---@param n lde.install.Node
	consume = function(n)
		consumeFromPkg(n)
	end,
	---@param n lde.install.Node
	---@return lde.Lockfile.Dependency
	lock = function(n)
		return { path = n.depInfo.path, name = n.depInfo.name, rockspec = n.depInfo.rockspec }
	end,
}

--- git (and registry): tarball content, package/deps found after extraction.
handlers.git = {
	---@param n lde.install.Node
	---@return lde.install.ContentPlan?
	content = function(n)
		const g = n.gitPlan --[[@as lde.install.GitPlan]]
		if g.tarballUrl then
			return { url = g.tarballUrl, file = g.archiveFile, dir = g.dir, kind = "git" }
		elseif g.clone then
			return { kind = "clone" } -- unrecognized host: git clone directly
		end
		return nil -- already cached
	end,
	---@param n lde.install.Node
	---@param c lde.install.ContentPlan
	materialize = function(n, c)
		if c.kind == "clone" then
			local clone = n.gitPlan --[[@as lde.install.GitPlan]].clone --[[@as { repoName: string, repoUrl: string, commit: string, branch: string? }]]
			local ok, err = lde.global.cloneDir(clone.repoName, clone.repoUrl, clone.commit, clone.branch)
			if not ok then lde.error.raise("Failed to clone git repository: " .. (err or "unknown error")) end
			return
		end
		local res = download.result(c.file --[[@as string]])
		if res and not res.ok then lde.error.raise("Failed to download " .. c.url .. ": " .. (res.err or "")) end
		local ok, err = lde.global.extractGitTarball(c.file --[[@as string]], c.dir --[[@as string]])
		if not ok then
			-- The seeded copy may itself be corrupt; don't let the next run
			-- re-trust (and re-fail on) it.
			download.invalidate(c.file --[[@as string]])
			lde.error.raise("Failed to extract " .. n.repoName .. ": " .. (err or ""))
		end
	end,
	---@param n lde.install.Node
	open = function(n)
		local gitPlan = n.gitPlan --[[@as lde.install.GitPlan]]
		local pkg, err = lde.util.findNamedPackage(gitPlan.dir, n.repoName, n.depInfo.rockspec)
		if not pkg then lde.error.raise(err or "No package found in git repository") end ---@cast pkg -nil
		n.pkg = pkg
		n.expandDir = pkg:getDir()
	end,
	---@param n lde.install.Node
	consume = function(n)
		consumeFromPkg(n)
	end,
	---@param n lde.install.Node
	---@return lde.Lockfile.Dependency
	lock = function(n)
		local gitPlan = n.gitPlan --[[@as lde.install.GitPlan]]
		-- Registry deps have no git field in their config entry; makeNode
		-- records the resolved repo URL on the plan (gitPlan.url) so it still
		-- gets pinned.
		return {
			git = gitPlan.url or n.depInfo.git,
			commit = gitPlan.commit,
			branch = n.depInfo.branch,
			name = n.depInfo.name,
			rockspec = n.depInfo.rockspec,
		}
	end,
}

--- archive: URL downloads into the tar cache, then the rockspec is found inside.
handlers.archive = {
	---@param n lde.install.Node
	---@return lde.install.ContentPlan
	content = function(n)
		local dir = lde.global.getArchiveDir(n.depInfo.archive)
		return { url = n.depInfo.archive, file = dir .. ".archive", dir = dir, kind = "archive" }
	end,
	---@param n lde.install.Node
	---@param c lde.install.ContentPlan
	materialize = function(n, c)
		local res = download.result(c.file --[[@as string]])
		if res and not res.ok then lde.error.raise("Failed to download archive '" .. c.url .. "': " .. (res.err or "")) end
		verifyMd5(n, c)
		local ok, err = lde.global.extractArchive(c.url --[[@as string]], c.file --[[@as string]], c.dir --[[@as string]])
		if not ok then
			download.invalidate(c.file --[[@as string]])
			lde.error.raise("Failed to extract archive '" .. c.url .. "': " .. (err or ""))
		end
		local source = n.spec?.source
		c.srcDir = lde.global.sourceDirFor(c.dir --[[@as string]], source?.dir, source?.file)
	end,
	---@param n lde.install.Node
	open = function(n)
		local c = content(n) --[[@as lde.install.ContentPlan]]
		-- .src.rock archives contain a rockspec + the source tree; the source
		-- is either a subdir next to the rockspec or the nested archive.
		local pkgDir, rockspecPath = c.dir, n.depInfo.rockspec
		if not n.depInfo.rockspec or not n.depInfo.archive:match("%.src%.rock$") then
			pkgDir = packageDirOf(n, c)
		end
		if n.depInfo.archive:match("%.src%.rock$") and not n.depInfo.rockspec then
			local srcDir, srcRockspec, merr = lde.util.materializeSrcRock(c.dir --[[@as string]])
			if not srcDir then
				lde.error.raise("Failed to load archive dependency '" .. n.alias .. "': " .. (merr or "unknown error"))
			end
			pkgDir, rockspecPath = srcDir, srcRockspec
		end
		local pkg, err = lde.Package.open(pkgDir, rockspecPath)
		if not pkg then lde.error.raise("Failed to load archive dependency '" .. n.alias .. "': " .. (err or "")) end ---@cast pkg -nil
		n.pkg = pkg
		n.expandDir = pkg:getDir()
	end,
	---@param n lde.install.Node
	consume = function(n)
		consumeFromPkg(n)
	end,
	---@param n lde.install.Node
	---@return lde.Lockfile.Dependency
	lock = function(n)
		return { archive = n.depInfo.archive, name = n.depInfo.name, rockspec = n.depInfo.rockspec }
	end,
}

--- luarocks: metadata is the published rockspec; content prefers the .src.rock
--- and falls back to the rockspec's own source artifact.
handlers.luarocks = {
	---@param n lde.install.Node
	---@return lde.install.ContentPlan?
	content = function(n)
		if n._content then return n._content end

		if n.srcUrl then
			local dir = lde.global.getArchiveDir(n.srcUrl)
			n._content = { url = n.srcUrl, file = dir .. ".archive", dir = dir, kind = "src" }
			return n._content
		end

		-- No src rock for this version: fall back to the rockspec's source.
		consume(n)
		const source = n.spec?.source
		if not source or not source.url then
			lde.error.raise("No source artifact for '" .. n.alias .. "'")
		end ---@cast source { url: string, branch: string?, tag: string? }
		local sourceUrl = source.url
		-- LuaRocks treats any of these as a git source: git://, git+https://,
		-- or a plain URL ending in .git; anything else is a plain archive.
		if sourceUrl:match("^git") or sourceUrl:match("%.git$") then
			sourceUrl = lde.util.normalizeGitUrl(sourceUrl)
			local fallback = lde.global.planGitRepo(n.name --[[@as string]], sourceUrl, source.branch or source.tag, nil)
			fallback.url = sourceUrl
			n._fallbackGit = fallback
			if fallback.tarballUrl then
				n._content = {
					url = fallback.tarballUrl,
					file = fallback.archiveFile,
					dir = fallback.dir,
					kind = "git",
				}
			elseif fallback.clone then
				n._content = { kind = "clone" }
			else
				-- Repo dir already cached: nothing to download or extract.
				n._content = nil
			end
		else
			local dir = lde.global.getArchiveDir(sourceUrl)
			n._content = { url = sourceUrl, file = dir .. ".archive", dir = dir, kind = "archive" }
		end
		return n._content
	end,
	---@param n lde.install.Node
	---@param c lde.install.ContentPlan
	materialize = function(n, c)
		if c.kind == "clone" then
			local fallback = n._fallbackGit --[[@as lde.install.GitPlan]]
			local clone = fallback.clone --[[@as { repoName: string, repoUrl: string, commit: string, branch: string? }]]
			local ok, err = lde.global.cloneDir(clone.repoName, clone.repoUrl, clone.commit, clone.branch)
			if not ok then lde.error.raise("Failed to clone git repository: " .. (err or "unknown error")) end
			return
		end
		local res = download.result(c.file --[[@as string]])
		if res and not res.ok then lde.error.raise("Failed to download " .. c.url .. ": " .. (res.err or "")) end
		verifyMd5(n, c)
		-- A git tarball lands in the git cache, whose layout is the repository
		-- root (the wrapper directory stripped); plain archives keep the published
		-- layout and resolve their source directory afterwards.
		local ok, err
		if c.kind == "git" then
			ok, err = lde.global.extractGitTarball(c.file --[[@as string]], c.dir --[[@as string]])
		else
			ok, err = lde.global.extractArchive(c.url --[[@as string]], c.file --[[@as string]], c.dir --[[@as string]])
		end
		if not ok then
			download.invalidate(c.file --[[@as string]])
			lde.error.raise("Failed to extract '" .. (c.url or c.dir) .. "': " .. (err or ""))
		end
		if c.kind ~= "git" then
			-- Rockspec source.url archive: the package lives in the source
			-- directory inside the extraction root (source.dir, or the single
			-- top-level directory), not at the root itself.
			const source = n.spec?.source
			c.srcDir = lde.global.sourceDirFor(c.dir --[[@as string]], source?.dir, source?.file)
		end
	end,
	---@param n lde.install.Node
	consume = function(n)
		if n.rockspecFile and fs.exists(n.rockspecFile) then
			local content = fs.read(n.rockspecFile) --[[@as string]]
			local ok, spec = rocked.parse(content)
			if not ok then
				lde.error.raise("Failed to parse rockspec '" .. tostring(n.rockspecUrl) .. "': " .. tostring(spec))
			end ---@cast spec rocked.raw.Output
			n.spec = spec
			n.deps = {}
			lde.util.addRockspecDeps(n.deps, spec.dependencies or {})
			-- Build backends (e.g. luarocks-build-rust-mlua) install alongside
			-- runtime deps so their modules resolve at build time.
			lde.util.addRockspecDeps(n.deps, spec.build_dependencies or {})
		elseif n.srcUrl then
			-- No published rockspec: read deps from the extracted content.
			local pkg = open(n)
			n.deps = pkg:readConfig().dependencies or {}
		else
			lde.error.raise("Missing rockspec for '" .. n.alias .. "': " .. tostring(n.rockspecUrl))
		end
	end,
	---@param n lde.install.Node
	open = function(n)
		local c = content(n)
		local pkg, err
		if c and c.kind == "src" then
			pkg, err = lde.util.openSrcRock(c.dir --[[@as string]], c.url --[[@as string]])
		else
			-- Rockspec-backed, or a git fallback whose repo dir was already
			-- cached (content() returns nil in that case).
			const pkgDir = (c and packageDirOf(n, c)) ?? n._fallbackGit?.dir ?? n.dir
			pkg, err = lde.Package.openRockspec(pkgDir, n.rockspecUrl)
		end
		if not pkg then lde.error.raise("Failed to load '" .. n.name .. "': " .. (err or "")) end ---@cast pkg -nil
		n.pkg = pkg
		n.expandDir = pkg:getDir()
	end,
	---@param n lde.install.Node
	---@return lde.Lockfile.Dependency
	lock = function(n)
		local c = content(n)
		if c and c.kind == "src" then
			return { archive = n.srcUrl }
		end
		if c and (c.kind == "git" or c.kind == "clone") then
			local fallback = n._fallbackGit --[[@as lde.install.GitPlan]]
			return { git = fallback.url, commit = fallback.commit, rockspec = n.rockspecUrl }
		end
		if c then
			return { archive = c.url, rockspec = n.rockspecUrl }
		end
		-- Cached git dir (content() returns nil): lock to the resolved git ref.
		local fallback = n._fallbackGit --[[@as lde.install.GitPlan]]
		return { git = fallback.url, commit = fallback.commit, rockspec = n.rockspecUrl }
	end,
}

--- Resolves the whole dependency graph onto `ctx.stack` and `ctx.order`.
---
--- Two-phase design: the graph is walked by fetching only small metadata
--- (published rockspecs) in parallel batches, then all content artifacts
--- (.src.rock files, source tarballs) are downloaded in one parallel batch,
--- and finally everything is extracted and opened. Git deps (and lockfile-
--- pinned archives) are the exception: their metadata lives inside the repo,
--- so their content is downloaded during the walk and they expand after it.
---
---@param dependencies table<string, lde.Package.Config.Dependency>
---@param ctx lde.install.Context
local function resolveDependencies(dependencies, ctx)
	---@type table<string, lde.install.Node>
	local graph = {} -- alias -> node
	---@type lde.install.Node[]
	local order = {} -- nodes in discovery order
	---@type lde.install.Node[]
	const failed = {} -- nodes whose download/extract failed (reported at the end)

	-- ── Phase 1: graph walk (metadata-only) ────────────────────────────────
	---@type lde.install.Node[]
	local frontier = addDeps(dependencies, ctx.relativeTo, ctx, graph, order)

	-- destPath -> node for .src.rock downloads backgrounded during the walk.
	-- Their URLs are known the moment a luarocks node is created (the URL
	-- cache resolves them without the rockspec), so they start downloading
	-- while the transitive rockspec fetches are still in flight. Phase 2
	-- collects them instead of re-prefetching.
	---@type table<string, lde.install.Node>
	const backgroundByFile = {}

	while #frontier > 0 do
		---@type lde.install.Node[]
		const nextFrontier = {}
		---@type lde.install.Node[]
		const metaBatch = {}
		---@type lde.install.Node[]
		const contentBatch = {}

		for _, node in ipairs(frontier) do
			-- A dep nothing wants is not expanded: what it would bring in is wanted by
			-- nobody -- it is only a dependency of the package that is not installed --
			-- and resolving it would install it anyway, for the package that isn't
			-- there. The node itself is still in the lockfile, since it is still what
			-- the manifest says; only its subtree is left out.
			if node.wanted == false then
				goto continue
			end

			if node.hasMetadata then
				-- Fetch the published rockspec (tiny) to discover deps.
				if not fs.exists(node.rockspecFile --[[@as string]]) then
					download.prefetch(node.rockspecUrl --[[@as string]], node.rockspecFile --[[@as string]])
				end
				metaBatch[#metaBatch + 1] = node
			elseif not node.isExpandAfter and not content(node) then
				-- path deps: nothing to download, consume and expand immediately.
				consume(node)
				for _, child in ipairs(addDeps(node.deps or {}, node.expandDir or ctx.relativeTo, ctx, graph, order, node)) do
					nextFrontier[#nextFrontier + 1] = child
				end
			end

			-- Luarocks deps with a known .src.rock: start the content download
			-- in the background now so it overlaps the rest of the walk. Only
			-- when the extraction dir isn't cached yet (the walk skips
			-- re-downloading otherwise). Content-backed git/archive nodes are
			-- handled by the isExpandAfter branch below.
			if node.kind == "luarocks" and node.srcUrl and not node.isExpandAfter then
				local c = content(node)
				if c and c.kind ~= "clone" and not fs.exists(c.dir --[[@as string]])
					and not backgroundByFile[c.file --[[@as string]]] then
					download.background(c.url --[[@as string]], c.file --[[@as string]])
					backgroundByFile[c.file --[[@as string]]] = node
				end
			end

			if node.isExpandAfter then
				-- Git deps / pinned archives: content is needed to expand.
				local c = content(node)
				if (c and c.dir and not fs.exists(c.dir)) or (c and c.kind == "clone") then
					if c.kind ~= "clone" then
						download.prefetch(c.url --[[@as string]], c.file --[[@as string]])
					end
					ctx.downloads += 1
					-- Lazily spawn the dependency's progress row (marker from
					-- the node kind alone; refined to 🛠️ once a build starts).
					if ctx.progress then
						ctx.progress:setCurrent(node.alias, node.kind == "luarocks" and "rock" or "wrench")
					end
					contentBatch[#contentBatch + 1] = node
				else
					-- Content already cached: consume + expand without downloading.
					consume(node)
					for _, child in ipairs(addDeps(node.deps or {}, node.expandDir or ctx.relativeTo, ctx, graph, order, node)) do
						nextFrontier[#nextFrontier + 1] = child
					end
				end
			end

			::continue::
		end

		download.drain()

		for _, node in ipairs(metaBatch) do
			consume(node)
			for _, child in ipairs(addDeps(node.deps or {}, node.expandDir or ctx.relativeTo, ctx, graph, order, node)) do
				nextFrontier[#nextFrontier + 1] = child
			end
		end

		for _, node in ipairs(contentBatch) do
			materialize(node)
			if node.error then
				-- Failed download/extract: keep resolving the rest of the graph
				-- (Phase 2 may retry it; remaining failures are reported
				-- together at the end).
				if ctx.progress then ctx.progress:finish(node.alias) end
				goto continue
			end
			consume(node)
			for _, child in ipairs(addDeps(node.deps or {}, node.expandDir or ctx.relativeTo, ctx, graph, order, node)) do
				nextFrontier[#nextFrontier + 1] = child
			end
			::continue::
		end

		frontier = nextFrontier
	end

	-- ── Phase 2: download all remaining content in one parallel batch ──────
	---@type lde.install.Node[]
	const contentNodes = {}
	---@type table<string, lde.install.Node>
	const contentByFile = {}
	for _, node in ipairs(order) do
		local c = content(node)
		-- Skip nodes whose content the walk already materialized (git clones
		-- have no cache dir to guard on, so without this they'd clone twice).
		if not node.isMaterialized and ((c and c.dir and not fs.exists(c.dir)) or (c and c.kind == "clone")) then
			if c.kind ~= "clone" then
				-- The walk may have already backgrounded this download; never
				-- enqueue it into the batch twice.
				if not backgroundByFile[c.file --[[@as string]]] then
					download.prefetch(c.url --[[@as string]], c.file --[[@as string]])
				end
				contentByFile[c.file --[[@as string]]] = node
			end
			ctx.downloads += 1
			-- Lazily spawn the dependency's progress row (marker from the node
			-- kind alone; refined to 🛠️ once a build starts).
			if ctx.progress then
				ctx.progress:setCurrent(node.alias, node.kind == "luarocks" and "rock" or "wrench")
			end
			contentNodes[#contentNodes + 1] = node
		end
	end

	-- Pipeline: as each download lands, materialize + open the node and queue
	-- its build, so independent compiles overlap the remaining downloads.
	download.onTransfer(function(destPath)
		local node = contentByFile[destPath]
		if not node then return end
		materialize(node)
		if node.error then
			if ctx.progress then ctx.progress:finish(node.alias) end
			return
		end
		ctx.build.addNode(node)
	end)
	download.drain()

	-- The walk's background prefetches aren't waited on by drain(); collect
	-- them (onTransfer materializes each as it lands, so this is a no-op for
	-- any that finished during the drains above).
	for file in pairs(backgroundByFile) do
		download.waitBackground(file)
	end

	-- Materialize anything the pipeline didn't (git clones have no transfer).
	for _, node in ipairs(contentNodes) do
		if not node.isMaterialized and not node.error then
			materialize(node)
			if node.error and ctx.progress then
				ctx.progress:finish(node.alias)
			end
		end
	end

	-- Queue the remaining nodes (cached/path deps never downloaded) for build.
	for _, node in ipairs(order) do
		if not node.error then ctx.build.addNode(node) end
	end

	-- ── Phase 3: open every package and record the stack ───────────────────
	-- Idempotent for nodes the pipeline already registered; the conflict
	-- check in registerNode still runs for every node.
	for _, node in ipairs(order) do
		if not node.error then registerNode(node, ctx) end
	end

	-- Nodes that still failed to download/extract (after the pipeline retried
	-- them) are reported after the build pass drains; the rest of the graph
	-- was still installed, and each failed node's cache state was cleaned so
	-- the next run re-fetches it.
	for _, node in ipairs(order) do
		if node.error and not node.isMaterialized then
			failed[#failed + 1] = node
		end
	end
	if #failed > 0 then ctx.failures = failed end

	-- Discovery order is a topological order (parents expand before their
	-- children), so the build pass can depend on it: build backends like
	-- luarocks-build-rust-mlua must land in target/ before the rock that
	-- requires them builds.
	ctx.order = order
end

return {
	resolveDependencies = resolveDependencies,
	registerNode = registerNode,
	enabledOptional = enabledOptional,
}
