const fs = require("fs")
const ansi = require("ansi")
const path = require("path")
const env = require("env")

const lde = require("lde-core")
local prompt = require("lde.util.prompt")

---@param args clap.Args
local function new(args)
	const opts = prompt.scaffoldOptions(args)
	const nameFlag = args:option("name")

	local name = args:pop()
	if not name then
		if not prompt.interactive then
			lde.error.raise("Usage: lde new <name>")
		end

		const asked = prompt.ask({ prompt = "Project name" })
		if not asked then
			os.exit(1)
		end
		if asked:find("[%s/\\]") then
			lde.error.raise("Invalid project name: '" .. asked .. "' (no spaces or path separators)")
		end
		name = asked
		opts.name = nameFlag or asked
	else
		opts.name = nameFlag or prompt.resolveName(args, path.basename(name))
	end

	-- A package named 'tests' would collide with the target/tests fixtures.
	const manifestName = opts.name or path.basename(name)
	if manifestName == "tests" then
		lde.error.raise("The name 'tests' is reserved for the test fixtures directory; choose another project name")
	end

	if fs.exists(name) then
		lde.error.raise("Directory " .. name .. " already exists")
	end

	const parent = path.dirname(name)
	if parent ~= "" and parent ~= "." and not fs.isdir(parent) then
		lde.error.raise("Cannot create '" .. name .. "': parent directory does not exist")
	end

	fs.mkdir(name)
	ansi.printf("{green}Created directory: %s", name)

	const package = lde.Package.init(path.resolve(env.cwd(), name), opts)
	if package and opts.language then
		prompt.ensureCompiler(opts.language)
	end

	return package
end

return new
