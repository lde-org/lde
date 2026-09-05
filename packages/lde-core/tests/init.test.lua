local test = require("lde-test")

local lde = require("lde-core")

local fs = require("fs")
local env = require("env")
local path = require("path")
local git2 = require("git2-sys")

local tmpBase = path.join(env.tmpdir(), "lde-init-tests")

-- Clean up from any previous test run
fs.rmdir(tmpBase)

--
-- Package.init (initialize)
--

test.it("Package.init creates lde.json in the target directory", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "new-project")
	fs.mkdir(dir)

	lde.Package.init(dir)

	test.truthy(fs.exists(path.join(dir, "lde.json")))
end)

test.it("Package.init uses the directory basename as the package name", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "my-lib")
	fs.mkdir(dir)

	lde.Package.init(dir)

	local pkg = assert(lde.Package.open(dir))
	test.equal(pkg:getName(), "my-lib")
end)

test.it("Package.init sets version to 0.1.0", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "versioned")
	fs.mkdir(dir)

	lde.Package.init(dir)

	local pkg = assert(lde.Package.open(dir))
	local config = pkg:readConfig()
	test.equal(config.version, "0.1.0")
end)

test.it("Package.init creates a src directory with init.lua", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "with-src")
	fs.mkdir(dir)

	lde.Package.init(dir)

	test.truthy(fs.exists(path.join(dir, "src")))
	test.truthy(fs.isfile(path.join(dir, "src", "init.lua")))
end)

test.it("Package.init creates a .gitignore", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "with-gitignore")
	fs.mkdir(dir)

	lde.Package.init(dir)

	test.truthy(fs.exists(path.join(dir, ".gitignore")))

	local content = fs.read(path.join(dir, ".gitignore"))
	test.truthy(content) ---@cast content -nil
	test.includes(content, "/target/")
end)

test.it("Package.init creates a .luarc.json", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "with-luarc")
	fs.mkdir(dir)

	lde.Package.init(dir)

	test.truthy(fs.isfile(path.join(dir, ".luarc.json")))
end)

test.it("Package.init errors if lde.json already exists", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "already-exists")
	fs.mkdir(dir)
	fs.write(path.join(dir, "lde.json"), '{"name":"existing","version":"1.0.0"}')

	local ok, err = pcall(lde.Package.init, dir)
	test.falsy(ok)
	test.truthy(err)
end)

test.it("Package.init result can be opened as a Package", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "openable")
	fs.mkdir(dir)

	local pkg = lde.Package.init(dir)
	test.truthy(pkg)

	local reopened, err = lde.Package.open(dir)
	test.truthy(reopened)
	test.falsy(err)
end)

test.it("Package.init skips git init when inside a nested subdir of a git repo", function()
	fs.mkdir(tmpBase)
	local repoDir = path.join(tmpBase, "parent-repo")
	fs.mkdir(repoDir)

	local repo, err = git2.init(repoDir)
	test.truthy(repo, err or "failed to init git")

	local nestedDir = path.join(repoDir, "deep", "nested")
	fs.mkdirAll(nestedDir)

	lde.Package.init(nestedDir)

	test.falsy(fs.exists(path.join(nestedDir, ".git")), "should not create nested .git")
end)

test.it("Package.init library type exposes a module from init.lua", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "lib-project")
	fs.mkdir(dir)

	lde.Package.init(dir, { type = "library" })

	local content = fs.read(path.join(dir, "src", "init.lua"))
	test.truthy(content) ---@cast content -nil
	test.includes(content, "local M = {}")
	test.includes(content, "return M")
end)

test.it("Package.init blank type keeps the hello-world entry point", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "blank-project")
	fs.mkdir(dir)

	lde.Package.init(dir, { type = "blank" })

	local content = fs.read(path.join(dir, "src", "init.lua"))
	test.truthy(content) ---@cast content -nil
	test.includes(content, "print('Hello, world!')")
end)

test.it("Package.init teal projects write a .tl entry point, check script, and tlconfig.lua", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "teal-project")
	fs.mkdir(dir)

	lde.Package.init(dir, { language = "teal" })

	test.truthy(fs.isfile(path.join(dir, "src", "init.tl")))
	test.falsy(fs.exists(path.join(dir, "src", "init.lua")))

	local pkg = assert(lde.Package.open(dir))
	local config = pkg:readConfig()
	local check = config.scripts and config.scripts.check
	test.truthy(check)
	if check then
		test.includes(check, "tl check -I target")
	end

	test.truthy(fs.isfile(path.join(dir, "tlconfig.lua")))
	local tlconfig = fs.read(path.join(dir, "tlconfig.lua")) ---@cast tlconfig -nil
	test.includes(tlconfig, "include_dir")
	test.falsy(fs.exists(path.join(dir, ".luarc.json")))
end)

--
-- Package.init: existing-file branches (never overwrite user files)
--

test.it("Package.init appends to an existing .gitignore that lacks /target/", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "gitignore-append")
	fs.mkdir(dir)
	fs.write(path.join(dir, ".gitignore"), "node_modules/\n")

	lde.Package.init(dir)

	local content = fs.read(path.join(dir, ".gitignore")) ---@cast content -nil
	test.includes(content, "node_modules/")
	test.includes(content, "/target/")
end)

test.it("Package.init leaves a .gitignore that already ignores target/ alone", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "gitignore-keep")
	fs.mkdir(dir)
	fs.write(path.join(dir, ".gitignore"), "/target/\n/lde.lock\n")

	lde.Package.init(dir)

	test.equal(fs.read(path.join(dir, ".gitignore")), "/target/\n/lde.lock\n")
end)

test.it("Package.init does not overwrite an existing src/ entry point", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "src-exists")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), 'return "mine"')

	lde.Package.init(dir)

	test.equal(fs.read(path.join(dir, "src", "init.lua")), 'return "mine"')
end)

test.it("Package.init does not overwrite an existing tlconfig.lua", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "tlconfig-exists")
	fs.mkdir(dir)
	fs.write(path.join(dir, "tlconfig.lua"), "return { custom = true }")

	lde.Package.init(dir, { language = "teal" })

	test.equal(fs.read(path.join(dir, "tlconfig.lua")), "return { custom = true }")
end)

test.it("Package.init does not overwrite an existing .luarc.json", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "luarc-exists")
	fs.mkdir(dir)
	fs.write(path.join(dir, ".luarc.json"), "{}")

	lde.Package.init(dir)

	test.equal(fs.read(path.join(dir, ".luarc.json")), "{}")
end)

test.skipIf(jit.os == "Windows" or env.var("CI") ~= nil)(
	"Package.init writes CLAUDE.md when claude is on PATH", function()
	-- Fake a `claude` binary so hasBinary() finds it; the agent instructions
	-- are only written when a known agent is present. Skipped on CI: the fake
	-- PATH mutates the shared process environment, which is risky inside a
	-- longer suite run.
	local binDir = path.join(tmpBase, "fake-bin")
	fs.rmdir(binDir)
	fs.mkdir(binDir)
	fs.write(path.join(binDir, "claude"), "#!/bin/sh\nexit 0\n")
	fs.chmod(path.join(binDir, "claude"), tonumber("755", 8))

	local oldPath = env.var("PATH") or ""
	-- Replace PATH entirely so real agents installed on the machine can't
	-- satisfy hasBinary(); Package.init doesn't need anything from PATH.
	env.set("PATH", binDir)

	local ok, err = pcall(function()
		local dir = path.join(tmpBase, "agent-template")
		fs.mkdir(dir)
		lde.Package.init(dir)
		test.truthy(fs.isfile(path.join(dir, "CLAUDE.md")), "CLAUDE.md should be written for claude users")
		test.truthy(fs.read(path.join(dir, "CLAUDE.md")):find("package manager and toolkit for Lua", 1, true))
	end)

	env.set("PATH", oldPath)
	if not ok then error(err) end
end)

test.skipIf(jit.os == "Windows" or env.var("CI") ~= nil)(
	"Package.init prefers AGENTS.md when other agents are on PATH", function()
	-- zed (an AGENTS.md harness) must win over claude: AGENTS.md is preferred.
	local binDir = path.join(tmpBase, "fake-bin-agents")
	fs.rmdir(binDir)
	fs.mkdir(binDir)
	for _, bin in ipairs({ "claude", "zed" }) do
		fs.write(path.join(binDir, bin), "#!/bin/sh\nexit 0\n")
		fs.chmod(path.join(binDir, bin), tonumber("755", 8))
	end

	local oldPath = env.var("PATH") or ""
	-- Replace PATH entirely (see the claude test above).
	env.set("PATH", binDir)

	local ok, err = pcall(function()
		local dir = path.join(tmpBase, "agent-template-agents")
		fs.mkdir(dir)
		lde.Package.init(dir)
		test.truthy(fs.isfile(path.join(dir, "AGENTS.md")), "AGENTS.md should be preferred over CLAUDE.md")
		test.falsy(fs.exists(path.join(dir, "CLAUDE.md")), "CLAUDE.md must not be written when an AGENTS.md agent is present")
	end)

	env.set("PATH", oldPath)
	if not ok then error(err) end
end)

test.it("Package.init moonscript projects write a .moon entry point and no extra scaffolding", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "moon-project")
	fs.mkdir(dir)

	lde.Package.init(dir, { language = "moonscript" })

	test.truthy(fs.isfile(path.join(dir, "src", "init.moon")))
	test.falsy(fs.exists(path.join(dir, "src", "init.lua")))

	local pkg = assert(lde.Package.open(dir))
	local config = pkg:readConfig()
	test.falsy(config.scripts)
	test.falsy(fs.exists(path.join(dir, "tlconfig.lua")))
	test.falsy(fs.exists(path.join(dir, ".luarc.json")))
end)

test.it("Package.init combines type and language for library modules", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "teal-lib")
	fs.mkdir(dir)

	lde.Package.init(dir, { type = "library", language = "teal" })

	local content = fs.read(path.join(dir, "src", "init.tl"))
	test.truthy(content) ---@cast content -nil
	test.includes(content, "return M")

	local moonDir = path.join(tmpBase, "moon-lib")
	fs.mkdir(moonDir)
	lde.Package.init(moonDir, { type = "library", language = "moonscript" })

	local moonContent = fs.read(path.join(moonDir, "src", "init.moon"))
	test.truthy(moonContent) ---@cast moonContent -nil
	test.includes(moonContent, "return M")
end)

test.it("Package.init rejects unknown types and languages", function()
	fs.mkdir(tmpBase)
	local badType = path.join(tmpBase, "bad-type")
	fs.mkdir(badType)
	local badOpts = { type = "bogus" } ---@type any
	local ok, err = pcall(lde.Package.init, badType, badOpts)
	test.falsy(ok)
	test.truthy(err)

	local badLang = path.join(tmpBase, "bad-lang")
	fs.mkdir(badLang)
	local badLangOpts = { language = "rust" } ---@type any
	local ok2, err2 = pcall(lde.Package.init, badLang, badLangOpts)
	test.falsy(ok2)
	test.truthy(err2)
end)

test.it("Package.init honors a name override in the manifest", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "dir-name")
	fs.mkdir(dir)

	lde.Package.init(dir, { name = "custom-name" })

	local pkg = assert(lde.Package.open(dir))
	test.equal(pkg:getName(), "custom-name")
end)

test.it("Package.init rejects names with spaces or separators", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "bad-name")
	fs.mkdir(dir)

	local ok, err = pcall(lde.Package.init, dir, { name = "bad name" })
	test.falsy(ok)
	test.truthy(err)

	local ok2, err2 = pcall(lde.Package.init, dir, { name = "bad/name" })
	test.falsy(ok2)
	test.truthy(err2)
end)

test.it("Package.init rejects the reserved 'tests' name", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "reserved-name")
	fs.mkdir(dir)

	local ok, err = pcall(lde.Package.init, dir, { name = "tests" })
	test.falsy(ok)
	test.truthy(err)
	if err then
		test.includes(tostring(err), "reserved")
	end

	-- The directory basename is checked too.
	local testsDir = path.join(tmpBase, "tests")
	fs.mkdir(testsDir)
	local ok2, err2 = pcall(lde.Package.init, testsDir)
	test.falsy(ok2)
	test.truthy(err2)
end)
