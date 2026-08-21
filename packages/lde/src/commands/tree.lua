local ansi = require("ansi")
local lde = require("lde-core")

---@type table<string, lde.Package.Config.FeatureFlag>
local platformLookup = {
	["Windows"] = "windows",
	["Linux"] = "linux",
	["OSX"] = "macos"
}

---@type ansi.Color[]
local depthColors = { "yellow", "magenta", "cyan" }

---@param features table<string, string[]>?
---@return table<string, true>
local function enabledOptionals(features)
	local enabled = {}
	if not features then return enabled end
	local platformDeps = features[platformLookup[jit.os]]
	if platformDeps then
		for _, name in ipairs(platformDeps) do
			enabled[name] = true
		end
	end
	return enabled
end

--- Merge a root lockfile entry onto a manifest dependency so git deps resolve
--- to their pinned commit. A dep's own lockfile is not authoritative — the
--- root lockfile flat-pins every alias in the tree — and manifest-only fields
--- (version, optional, features) must survive the merge.
---@param info lde.Package.Config.Dependency
---@param locked table<string, lde.Lockfile.Dependency>
---@param name string
---@return lde.Package.Config.Dependency
local function mergeLocked(info, locked, name)
	local entry = locked[name]
	if not entry then return info end
	local merged = {}
	for k, v in pairs(info) do merged[k] = v end
	for k, v in pairs(entry) do
		if v ~= nil then merged[k] = v end
	end
	return merged
end

--- The package's runtime dependencies, each merged with the root lockfile.
---@param pkg lde.Package
---@param locked table<string, lde.Lockfile.Dependency>
---@return table<string, lde.Package.Config.Dependency>
local function getMergedDeps(pkg, locked)
	local merged = {}
	for name, info in pairs(pkg:getDependencies()) do
		merged[name] = mergeLocked(info, locked, name)
	end
	return merged
end

--- Open a dependency as a package so the tree can walk its own deps. Rocks
--- deps resolve to a content dir with no lde.json, so they open with their
--- rockspec (or scan for one in the dir).
---@param pkg lde.Package
---@param name string
---@param info lde.Package.Config.Dependency
---@return lde.Package? depPkg
---@return string? err
local function openDep(pkg, name, info)
	local depPath, err = pkg:getDependencyPath(name, info)
	if not depPath then return nil, err end
	return lde.Package.open(depPath, info.rockspec)
end

--- Mark every alias that lies on a root->target path (the --why highlight
--- set). `chain` holds the aliases from the root to `pkg` (inclusive);
--- `inChain` guards against cycles.
---@param pkg lde.Package
---@param target string
---@param locked table<string, lde.Lockfile.Dependency>
---@param chain string[]
---@param inChain table<string, true>
---@param relevant table<string, true>
local function collectRelevant(pkg, target, locked, chain, inChain, relevant)
	for name, info in pairs(getMergedDeps(pkg, locked)) do
		if name == target then
			for _, node in ipairs(chain) do relevant[node] = true end
			relevant[name] = true
		end
		if not inChain[name] then
			local depPkg = openDep(pkg, name, info)
			if depPkg then
				chain[#chain + 1] = name
				inChain[name] = true
				collectRelevant(depPkg, target, locked, chain, inChain, relevant)
				inChain[name] = nil
				chain[#chain] = nil
			end
		end
	end
end

---@param args clap.Args
local function tree(args)
	local whyName = args:option("why")

	local pkg, err = lde.Package.open()
	if not pkg then
		lde.error.raise(err)
	end ---@cast pkg -nil

	local rootName = pkg:getName()

	-- The root lockfile flat-pins every resolved alias in the tree; merge it
	-- into each package's manifest deps as the tree walks (a dep's own
	-- lockfile is not authoritative for transitive pins).
	local lockfile = pkg:readLockfile()
	local locked = {}
	if lockfile and not lockfile:isStale(pkg:readConfig()) then
		locked = lockfile.raw.dependencies or {}
	end

	---@type table<string, true>?
	local relevant
	if whyName and whyName ~= rootName then
		relevant = { [rootName] = true }
		collectRelevant(pkg, whyName, locked, { rootName }, { [rootName] = true }, relevant)
		if not relevant[whyName] then
			lde.error.raise("'" .. whyName .. "' is not a dependency of " .. rootName, {
				hint = "Run `lde sync` first — transitive dependencies are resolved from the lockfile.",
			})
		end
	end

	---@param pkg lde.Package
	---@param displayName string? # the require alias for dep nodes (nil for the root)
	---@param cfg lde.Package.Config.Dependency?
	---@param depth number
	---@param prefix string
	---@param isLast boolean
	local function printTree(pkg, displayName, cfg, depth, prefix, isLast)
		local connector = depth == 0 and "" or (isLast and "└── " or "├── ")
		local name = displayName or pkg:getName()
		-- With --why, everything off the root->target path is dimmed.
		local color = (not relevant or relevant[name]) and depthColors[depth % #depthColors + 1] or "gray"
		local rendered = ansi.colorize(color, name)

		if cfg then
			local desc
			if cfg.git then
				desc = "git: " .. cfg.git
			elseif cfg.path then
				desc = "path: " .. cfg.path
			elseif cfg.luarocks then
				desc = "luarocks: " .. cfg.luarocks
			end
			ansi.printf("%s%s%s {gray}(%s)", prefix, connector, rendered, desc)
		else
			ansi.printf("%s%s%s", prefix, connector, rendered)
		end

		local childPrefix = depth == 0 and "" or (prefix .. (isLast and "    " or "│   "))

		local deps = {} ---@type { name: string, info: lde.Package.Config.Dependency }[]
		for depName, info in pairs(getMergedDeps(pkg, locked)) do
			deps[#deps + 1] = { name = depName, info = info }
		end
		table.sort(deps, function(a, b) return a.name < b.name end)

		local features = pkg:readConfig().features
		local enabled = enabledOptionals(features)

		for i, dep in ipairs(deps) do
			local last = i == #deps
			local info = dep.info

			if info.optional and not enabled[dep.name] then
				local treeChar = last and "└── " or "├── "
				ansi.printf("%s%s{gray}%s {gray}(optional, skipped on %s)", childPrefix, treeChar, dep.name, jit.os)
			else
				local depPkg, derr = openDep(pkg, dep.name, info)
				if not depPkg then
					local treeChar = last and "└── " or "├── "
					local why = derr or "not installed yet — run `lde sync`"
					ansi.printf("%s%s{red}%s {gray}(%s)", childPrefix, treeChar, dep.name, why)
				else
					printTree(depPkg, dep.name, info, depth + 1, childPrefix, last)
				end
			end
		end
	end

	printTree(pkg, nil, nil, 0, "", true)
end

return tree
