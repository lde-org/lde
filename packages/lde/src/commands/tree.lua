const ansi = require("ansi")
const lde = require("lde-core")

const features = require("lde-core.package.features")

const depthColors = { "yellow", "magenta", "cyan" }

--- Shared with the resolver so `lde tree` can never disagree with an install.
---@param defs table<string, lde.Package.Config.FeatureDefinition>?
local function enabledOptionals(defs)
	return features.enabledDependencies(defs, nil)
end

--- Root lockfile entries flat-pin every alias and must win over a dep's own lockfile.
---@param info lde.Package.Config.Dependency
---@param locked table<string, lde.Lockfile.Dependency>
---@param name string
---@return lde.Package.Config.Dependency
local function mergeLocked(info, locked, name)
	const entry = locked[name]
	if not entry then return info end
	local merged = {}
	for k, v in pairs(info) do merged[k] = v end
	for k, v in pairs(entry) do
		if v ~= nil then merged[k] = v end
	end
	return merged
end

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

--- Rocks deps have no lde.json, so they open with their rockspec.
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

--- Mark every alias on a root->target path for --why; `inChain` guards against cycles.
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

	const lockfile = pkg:readLockfile()
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
		local connector = depth == 0 ? "" : isLast ? "└── " : "├── "
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

		local childPrefix = depth == 0 ? "" : prefix .. (isLast ? "    " : "│   ")

		local deps = {} ---@type { name: string, info: lde.Package.Config.Dependency }[]
		for depName, info in pairs(getMergedDeps(pkg, locked)) do
			deps[#deps + 1] = { name = depName, info = info }
		end
		table.sort(deps, |a, b| -> a.name < b.name)

		const enabled = enabledOptionals(features.of(pkg))

		for i, dep in ipairs(deps) do
			const last = i == #deps
			local info = dep.info

			if info.optional and not enabled[dep.name] then
				local treeChar = last ? "└── " : "├── "
				ansi.printf("%s%s{gray}%s {gray}(optional, skipped on %s)", childPrefix, treeChar, dep.name, jit.os)
			else
				local depPkg, derr = openDep(pkg, dep.name, info)
				if not depPkg then
					local treeChar = last ? "└── " : "├── "
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
