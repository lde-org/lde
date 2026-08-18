local fs = require("fs")
local ansi = require("ansi")
local path = require("path")
local env = require("env")

local lde = require("lde-core")
local prompt = require("lde.util.prompt")

---@param args clap.Args
local function new(args)
	local opts = prompt.scaffoldOptions(args)

	local name = args:pop()
	if not name then
		if not prompt.interactive then
			lde.error.raise("Usage: lde new <name>")
		end

		-- No name given: ask for it — it names both the directory and the package.
		local asked = prompt.ask({ prompt = "Project name" })
		if not asked then
			os.exit(1)
		end
		if asked:find("[%s/\\]") then
			lde.error.raise("Invalid project name: '" .. asked .. "' (no spaces or path separators)")
		end
		name = asked
		opts.name = asked
	else
		opts.name = prompt.resolveName(args, path.basename(name))
	end

	-- The tests/ fixtures are exposed as target/tests during lde test, so a
	-- package named 'tests' would collide with them. Fail before creating
	-- anything.
	local manifestName = opts.name or path.basename(name)
	if manifestName == "tests" then
		lde.error.raise("The name 'tests' is reserved for the test fixtures directory; choose another project name")
	end

	if fs.exists(name) then
		lde.error.raise("Directory " .. name .. " already exists")
	end

	local parent = path.dirname(name)
	if parent ~= "" and parent ~= "." and not fs.isdir(parent) then
		lde.error.raise("Cannot create '" .. name .. "': parent directory does not exist")
	end

	fs.mkdir(name)
	ansi.printf("{green}Created directory: %s", name)

	local package = lde.Package.init(path.resolve(env.cwd(), name), opts)
	if package and opts.language then
		prompt.ensureCompiler(opts.language)
	end

	return package
end

return new
