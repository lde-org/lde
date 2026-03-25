local ansi = require("ansi")

local lpm = require("lpm-core")

---@type ansi.Color[]
local depthColors = {
	"yellow",
	"magenta",
	"cyan"
}

---@param _args clap.Args
local function tree(_args)
	---@param pkg lpm.Package
	---@param cfg lpm.Config.Dependency?
	---@param depth number?
	local function printTree(pkg, cfg, depth)
		depth = depth or 0

		local indent = string.rep("  ", depth)
		local name = ansi.colorize(depthColors[depth % #depthColors + 1], pkg:getName())

		if cfg then
			local desc
			if cfg.git then
				desc = "git: " .. cfg.git
			elseif cfg.path then
				desc = "path: " .. cfg.path
			end

			ansi.printf("%s%s {gray}(%s)", indent, name, desc)
		else
			ansi.printf("%s%s", indent, name)
		end

		local deps = {} ---@type { name: string, info: lpm.Config.Dependency }[]
		for name, info in pairs(pkg:getDependencies()) do
			deps[#deps + 1] = { name = name, info = info }
		end

		table.sort(deps, function(a, b)
			return a.name < b.name
		end)

		for _, dep in ipairs(deps) do
			local pkg, err = lpm.Package.open(pkg:getDependencyPath(dep.name, dep.info))
			if not pkg then
				ansi.printf("%s  {red}Failed to open package: %s", indent, err)
				goto skip
			end

			printTree(pkg, dep.info, depth + 1)
			::skip::
		end
	end

	local pkg, err = lpm.Package.open()
	if not pkg then
		ansi.printf("{red}%s", err)
		return
	end

	printTree(pkg)
end

return tree
