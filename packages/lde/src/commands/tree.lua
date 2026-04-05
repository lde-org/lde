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

---@param _args clap.Args
local function tree(_args)
	---@param pkg lde.Package
	---@param cfg lde.Package.Config.Dependency?
	---@param depth number
	---@param prefix string
	---@param isLast boolean
	local function printTree(pkg, cfg, depth, prefix, isLast)
		local connector = depth == 0 and "" or (isLast and "└── " or "├── ")
		local name = ansi.colorize(depthColors[depth % #depthColors + 1], pkg:getName())

		if cfg then
			local desc
			if cfg.git then
				desc = "git: " .. cfg.git
			elseif cfg.path then
				desc = "path: " .. cfg.path
			end
			ansi.printf("%s%s%s {gray}(%s)", prefix, connector, name, desc)
		else
			ansi.printf("%s%s%s", prefix, connector, name)
		end

		local childPrefix = depth == 0 and "" or (prefix .. (isLast and "    " or "│   "))

		local deps = {} ---@type { name: string, info: lde.Package.Config.Dependency }[]
		for depName, info in pairs(pkg:getDependencies()) do
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
				local depPkg, err = lde.Package.open(pkg:getDependencyPath(dep.name, info))
				if not depPkg then
					local treeChar = last and "└── " or "├── "
					ansi.printf("%s%s{red}%s {gray}(error: %s)", childPrefix, treeChar, dep.name, err)
				else
					printTree(depPkg, info, depth + 1, childPrefix, last)
				end
			end
		end
	end

	local pkg, err = lde.Package.open()
	if not pkg then
		ansi.printf("{red}%s", err)
		return
	end

	printTree(pkg, nil, 0, "", true)
end

return tree
