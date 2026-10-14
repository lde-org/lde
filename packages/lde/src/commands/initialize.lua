const env = require("env")
const fs = require("fs")
const path = require("path")

const lde = require("lde-core")
const prompt = require("lde.util.prompt")

---@param args clap.Args
local function init(args)
	const opts = prompt.scaffoldOptions(args)
	-- Consume the --name option before popping the positional so both orders of `lde init` parse the same.
	const nameFlag = args:option("name")

	local dir = args:pop() or env.cwd()

	-- Fail fast (and before any interactive prompts) when this is already a project.
	const configPath = path.join(dir, "lde.json")
	if fs.exists(configPath) or fs.exists(path.join(dir, "lpm.json")) then
		lde.error.raise("Directory already contains lde.json: " .. dir)
	end

	opts.name = nameFlag or prompt.resolveName(args, path.basename(dir))

	const package = lde.Package.init(dir, opts)
	if package and opts.language then
		prompt.ensureCompiler(opts.language)
	end

	return package
end

return init
