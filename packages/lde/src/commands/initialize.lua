local env = require("env")
local fs = require("fs")
local path = require("path")

local lde = require("lde-core")
local prompt = require("lde.util.prompt")

---@param args clap.Args
local function init(args)
	local opts = prompt.scaffoldOptions(args)
	-- Consume the --name option before popping the positional so
	-- `lde init --name foo [dir]` parses the same as `lde init [dir] --name foo`.
	local nameFlag = args:option("name")

	local dir = args:pop() or env.cwd()

	-- Fail fast (and before any interactive prompts) when this is already a project.
	local configPath = path.join(dir, "lde.json")
	if fs.exists(configPath) or fs.exists(path.join(dir, "lpm.json")) then
		lde.error.raise("Directory already contains lde.json: " .. dir)
	end

	opts.name = nameFlag or prompt.resolveName(args, path.basename(dir))

	local package = lde.Package.init(dir, opts)
	if package and opts.language then
		prompt.ensureCompiler(opts.language)
	end

	return package
end

return init
