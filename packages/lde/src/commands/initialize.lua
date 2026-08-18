local env = require("env")
local fs = require("fs")
local path = require("path")

local lde = require("lde-core")
local prompt = require("lde.util.prompt")

---@param args clap.Args
local function init(args)
	local dir = args:pop() or env.cwd()

	-- Fail fast (and before any interactive prompts) when this is already a project.
	local configPath = path.join(dir, "lde.json")
	if fs.exists(configPath) or fs.exists(path.join(dir, "lpm.json")) then
		lde.error.raise("Directory already contains lde.json: " .. dir)
	end

	local opts = prompt.scaffoldOptions(args)
	opts.name = prompt.resolveName(args, path.basename(dir))

	local package = lde.Package.init(dir, opts)
	if package and opts.language then
		prompt.ensureCompiler(opts.language)
	end

	return package
end

return init
