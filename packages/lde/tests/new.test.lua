local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")
local process = require("process")

local ldePath = assert(env.execPath())

local tmpBase = path.join(env.tmpdir(), "lde-new-tests")

-- Clean up from any previous test run
fs.rmdir(tmpBase)

---Run the lde binary, merging stdout and stderr. The plain ldecli helper only
---surfaces one stream, but scaffolding errors (error() tracebacks) go to
---stderr while stdout stays empty.
---@param args string[]
---@param cwd string?
---@return boolean, string
local function ldecli(args, cwd)
	local code, stdout, stderr = process.exec(ldePath, args, { cwd = cwd })
	return code == 0, (stdout or "") .. (stderr or "")
end

---@param dir string
---@return lde.Package.Config
local function readConfig(dir)
	local content = fs.read(path.join(dir, "lde.json"))
	assert(content, "no lde.json in " .. dir)
	return json.decode(content) --[[@as lde.Package.Config]]
end

test.it("lde new defaults to a blank Lua project", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "blank-default")

	local ok, out = ldecli({ "new", "blank-default" }, tmpBase)
	test.truthy(ok)
	test.includes(out or "", "Created directory")

	test.truthy(fs.isfile(path.join(dir, "src", "init.lua")))
	local content = fs.read(path.join(dir, "src", "init.lua"))
	test.includes(content or "", "print('Hello, world!')")

	local config = readConfig(dir)
	test.falsy(config.scripts)
	test.falsy(fs.exists(path.join(dir, "tlconfig.lua")))
end)

test.it("lde new --type library generates a module entry point", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "lib")

	local ok, out = ldecli({ "new", "--type", "library", "lib" }, tmpBase)
	test.truthy(ok)
	test.includes(out or "", "Created directory")

	local content = fs.read(path.join(dir, "src", "init.lua"))
	test.includes(content or "", "local M = {}")
	test.includes(content or "", "return M")
	test.falsy((content or ""):find("Hello, world!", 1, true))
end)

test.it("lde new --language teal writes .tl entry, check script, and tlconfig.lua", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "teal")

	local ok = ldecli({ "new", "teal", "--language", "teal" }, tmpBase)
	test.truthy(ok)

	test.truthy(fs.isfile(path.join(dir, "src", "init.tl")))
	test.falsy(fs.exists(path.join(dir, "src", "init.lua")))

	local config = readConfig(dir)
	local check = config.scripts and config.scripts.check
	test.truthy(check)
	if check then
		test.includes(check, "tl check -I target")
		test.includes(check, "src/init.tl")
	end

	test.truthy(fs.isfile(path.join(dir, "tlconfig.lua")))
end)

test.it("lde new --language moonscript writes a .moon entry point", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "moon")

	local ok = ldecli({ "new", "--language", "moonscript", "moon" }, tmpBase)
	test.truthy(ok)

	test.truthy(fs.isfile(path.join(dir, "src", "init.moon")))
	test.falsy(fs.exists(path.join(dir, "src", "init.lua")))

	-- No check script or tlconfig for moonscript
	local config = readConfig(dir)
	test.falsy(config.scripts)
	test.falsy(fs.exists(path.join(dir, "tlconfig.lua")))
end)

test.it("lde new combines --type library with --language teal", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "teal-lib")

	local ok = ldecli({ "new", "--type", "library", "--language", "teal", "teal-lib" }, tmpBase)
	test.truthy(ok)

	local content = fs.read(path.join(dir, "src", "init.tl"))
	test.includes(content or "", "return M")
	test.truthy(fs.isfile(path.join(dir, "tlconfig.lua")))
end)

test.it("lde init applies the same scaffolding options", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "init-me")

	local ok = ldecli({ "init", "init-me", "--type", "library", "--language", "moonscript" }, tmpBase)
	test.truthy(ok)

	test.truthy(fs.isfile(path.join(dir, "src", "init.moon")))
	local content = fs.read(path.join(dir, "src", "init.moon"))
	test.includes(content or "", "return M")
	test.truthy(fs.isfile(path.join(dir, "lde.json")))
end)

test.it("lde init refuses to re-initialize an existing project", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "existing")
	fs.mkdir(dir)
	fs.write(path.join(dir, "lde.json"), json.encode({ name = "existing", version = "0.1.0" }))

	local ok, out = ldecli({ "init", "existing" }, tmpBase)
	test.falsy(ok)
	test.includes(out or "", "already contains lde.json")
end)

test.it("lde new rejects invalid --type and --language values", function()
	fs.mkdir(tmpBase)

	local ok, out = ldecli({ "new", "--type", "bogus", "bad-type" }, tmpBase)
	test.falsy(ok)
	test.includes(out or "", "Invalid --type")

	local ok2, out2 = ldecli({ "new", "--language", "rust", "bad-lang" }, tmpBase)
	test.falsy(ok2)
	test.includes(out2 or "", "Invalid --language")
end)

test.it("lde new errors when the directory already exists", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "taken")
	fs.mkdir(dir)

	local ok, out = ldecli({ "new", "taken" }, tmpBase)
	test.falsy(ok)
	test.includes(out or "", "already exists")
end)

test.it("lde new without a name fails fast when non-interactive", function()
	fs.mkdir(tmpBase)

	-- Non-interactive (piped) runs must error up front, before any prompting.
	local ok, out = ldecli({ "new" }, tmpBase)
	test.falsy(ok)
	test.includes(out or "", "Usage: lde new <name>")
end)

test.it("lde new rejects the reserved 'tests' name", function()
	fs.mkdir(tmpBase)

	-- As the directory name.
	local ok, out = ldecli({ "new", "tests" }, tmpBase)
	test.falsy(ok)
	test.includes(out or "", "reserved")
	test.falsy(fs.exists(path.join(tmpBase, "tests")))

	-- As the manifest name override.
	local ok2, out2 = ldecli({ "new", "fine-name", "--name", "tests" }, tmpBase)
	test.falsy(ok2)
	test.includes(out2 or "", "reserved")
	test.falsy(fs.exists(path.join(tmpBase, "fine-name")))
end)

test.it("lde new accepts an absolute path", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "abs-proj")

	local ok = ldecli({ "new", dir }, tmpBase)
	test.truthy(ok)

	test.truthy(fs.isfile(path.join(dir, "src", "init.lua")))
	local content = fs.read(path.join(dir, "src", "init.lua"))
	test.includes(content or "", "Hello, world!")
end)

test.it("lde new --name overrides the manifest name", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "dir-name")

	local ok = ldecli({ "new", "dir-name", "--name", "manifest-name" }, tmpBase)
	test.truthy(ok)

	local config = readConfig(dir)
	test.equal(config.name, "manifest-name")

	-- The directory itself keeps the positional name.
	test.truthy(fs.isdir(path.join(tmpBase, "dir-name")))
	test.falsy(fs.exists(path.join(tmpBase, "manifest-name")))
end)
