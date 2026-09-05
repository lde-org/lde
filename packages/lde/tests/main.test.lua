local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")
local git2 = require("git2-sys")

local lde = require("lde-core")

local ldecli = require("tests.lib.ldecli")

test.it("should not ignore --git in ldx", function()
	local cloneUrl = "https://github.com/codebycruz/hood"

	-- Resolve the real commit so the cache key matches what getOrCloneRepo expects.
	local commit = assert(git2.lsRemote(cloneUrl, "HEAD")) ---@cast commit string

	-- Pre-populate the cache with a fake repo that lacks a "triangle" package.
	local repoDir = lde.global.getGitRepoDir("hood", commit)
	fs.rmdir(repoDir)
	fs.mkdir(repoDir)
	fs.write(path.join(repoDir, "lde.json"), json.encode({
		name = "hood",
		version = "1.0.0",
		dependencies = {}
	}))
	fs.mkdir(path.join(repoDir, "src"))
	fs.write(path.join(repoDir, "src", "init.lua"), "")

	local _, out = ldecli { "x", "triangle", "--git", cloneUrl } ---@cast out -nil
	test.falsy(out:find("not found in lde registry"))
	test.includes(out, "No package named 'triangle'")

	fs.rmdir(repoDir)
end)

test.it("ldx gh:owner/repo resolves the shorthand to a git repo", function()
	local cloneUrl = "https://github.com/codebycruz/hood"

	-- Resolve the real commit so the cache key matches what getOrCloneRepo expects.
	local commit = assert(git2.lsRemote(cloneUrl, "HEAD")) ---@cast commit string

	-- Pre-populate the cache with a fake repo (same trick as the --git test above).
	local repoDir = lde.global.getGitRepoDir("hood", commit)
	fs.rmdir(repoDir)
	fs.mkdir(repoDir)
	fs.write(path.join(repoDir, "lde.json"), json.encode({
		name = "hood",
		version = "1.0.0",
		dependencies = {}
	}))
	fs.mkdir(path.join(repoDir, "src"))
	fs.write(path.join(repoDir, "src", "init.lua"), 'print("from shorthand hood")')

	-- The repo root package runs, exactly as `ldx --git <url>` would.
	local ok, out = ldecli({ "x", "gh:codebycruz/hood" })
	test.truthy(ok, "ldx gh:... failed: " .. tostring(out)) ---@cast out -nil
	test.includes(out, "from shorthand hood")

	-- An extra positional is a sub-package name, like --git's [package-name].
	local _, out2 = ldecli({ "x", "gh:codebycruz/hood", "triangle" }) ---@cast out2 -nil
	test.includes(out2, "No package named 'triangle'")

	fs.rmdir(repoDir)
end)

test.it("ldx gh:<pkg>@owner/repo runs the sub-package of a monorepo", function()
	local cloneUrl = "https://github.com/codebycruz/hood"

	-- Resolve the real commit so the cache key matches what getOrCloneRepo expects.
	local commit = assert(git2.lsRemote(cloneUrl, "HEAD")) ---@cast commit string

	-- Pre-populate the cache with a fake monorepo: a root package plus a
	-- "triangle" package in a subdirectory.
	local repoDir = lde.global.getGitRepoDir("hood", commit)
	fs.rmdir(repoDir)
	fs.mkdir(repoDir)
	fs.write(path.join(repoDir, "lde.json"), json.encode({
		name = "hood",
		version = "1.0.0",
		dependencies = {}
	}))
	fs.mkdir(path.join(repoDir, "src"))
	fs.write(path.join(repoDir, "src", "init.lua"), "")
	fs.mkdir(path.join(repoDir, "triangle"))
	fs.mkdir(path.join(repoDir, "triangle", "src"))
	fs.write(path.join(repoDir, "triangle", "lde.json"), json.encode({
		name = "triangle",
		version = "1.0.0",
		dependencies = {}
	}))
	fs.write(path.join(repoDir, "triangle", "src", "init.lua"), 'print("from triangle subpackage")')

	local ok, out = ldecli({ "x", "gh:triangle@codebycruz/hood" })
	test.truthy(ok, "ldx gh:<pkg>@... failed: " .. tostring(out)) ---@cast out -nil
	test.includes(out, "from triangle subpackage")

	fs.rmdir(repoDir)
end)

test.it("ldx gh:owner/repo@version rejects malformed shorthands", function()
	local ok, out = ldecli({ "x", "gh:foo/bar@1.0.0" })
	test.falsy(ok)
	test.includes(tostring(out), "Invalid git shorthand")
end)

test.it("lde test skips packages with no tests/ directory", function()
	local tmpDir = path.join(env.tmpdir(), "lde-test-skip-test")
	fs.rmdir(tmpDir)
	fs.mkdir(tmpDir)

	-- Package with tests/
	local withTests = path.join(tmpDir, "with-tests")
	fs.mkdir(withTests)
	fs.mkdir(path.join(withTests, "src"))
	fs.mkdir(path.join(withTests, "tests"))
	fs.write(path.join(withTests, "src", "init.lua"), "return true")
	fs.write(path.join(withTests, "lde.json"), json.encode({ name = "with-tests", version = "0.1.0" }))
	fs.write(path.join(withTests, "tests", "dummy.test.lua"), [[
		local test = require("lde-test")
		test.it("dummy passes", function() end)
	]])

	-- Package without tests/ (has a dep that would get installed if erroneously picked up)
	local noTests = path.join(tmpDir, "no-tests")
	fs.mkdir(noTests)
	fs.mkdir(path.join(noTests, "src"))
	fs.write(path.join(noTests, "src", "init.lua"), "return true")
	fs.write(path.join(noTests, "lde.json"), json.encode({
		name = "no-tests",
		version = "0.1.0"
	}))

	local ok, out = ldecli({ "test" }, tmpDir)
	test.truthy(ok) ---@cast out -nil
	test.includes(out, "dummy passes")
	-- The package without tests/ should not appear in output at all
	test.falsy(out:find("no%-tests", 1, false))

	fs.rmdir(tmpDir)
end)

test.it("lde test monorepo mode runs each package from its own cwd", function()
	local tmpDir = path.join(env.tmpdir(), "lde-test-monorepo-cwd")
	fs.rmdir(tmpDir)
	fs.mkdir(tmpDir)

	-- Two packages whose tests read a cwd-relative fixture. The fixture only
	-- exists inside the package dir, so the read succeeds only when the
	-- package runs from its own directory (the cwd `lde test -C <pkg>` uses),
	-- never from the monorepo root.
	local testSource = [[
		local test = require("lde-test")
		test.it("reads a cwd-relative fixture", function()
			local f = assert(io.open("fixtures/marker.txt"))
			local content = f:read("*a")
			f:close()
			test.includes(content, "marker")
		end)
	]]
	for _, name in ipairs({ "pkg-one", "pkg-two" }) do
		local pkg = path.join(tmpDir, name)
		fs.mkdirAll(path.join(pkg, "src"))
		fs.mkdirAll(path.join(pkg, "tests"))
		fs.mkdir(path.join(pkg, "fixtures"))
		fs.write(path.join(pkg, "src", "init.lua"), 'return "' .. name .. '"')
		fs.write(path.join(pkg, "lde.json"), json.encode({ name = name, version = "0.1.0" }))
		fs.write(path.join(pkg, "fixtures", "marker.txt"), "marker from " .. name .. "\n")
		fs.write(path.join(pkg, "tests", "cwd.test.lua"), testSource)
	end

	local ok, out = ldecli({ "test" }, tmpDir)
	test.truthy(ok, "monorepo lde test must run packages from their own cwd: " .. tostring(out))
	test.includes(out or "", "pkg-one")
	test.includes(out or "", "pkg-two")

	fs.rmdir(tmpDir)
end)

test.it("lde test silences install/build output", function()
	local tmpDir = path.join(env.tmpdir(), "lde-test-quiet-output")
	fs.rmdir(tmpDir)
	fs.mkdir(tmpDir)

	-- A path dep with a build.lua, so `lde test` actually installs and builds
	-- something before running the tests.
	local depDir = path.join(tmpDir, "quiet-dep")
	fs.mkdir(depDir)
	fs.mkdir(path.join(depDir, "src"))
	fs.write(path.join(depDir, "src", "init.lua"), "return {}")
	fs.write(path.join(depDir, "lde.json"), json.encode({
		name = "quiet-dep",
		version = "0.1.0",
		dependencies = {}
	}))
	fs.write(path.join(depDir, "build.lua"), [[
		local build = require("lde-build")
		build:sh("echo QUIET-MARKER")
		build:write("init.lua", "return {}")
	]])

	local pkg = path.join(tmpDir, "quiet-pkg")
	fs.mkdir(pkg)
	fs.mkdir(path.join(pkg, "src"))
	fs.write(path.join(pkg, "src", "init.lua"), 'return "quiet-pkg"')
	fs.write(path.join(pkg, "lde.json"), json.encode({
		name = "quiet-pkg",
		version = "0.1.0",
		dependencies = { ["quiet-dep"] = { path = "../quiet-dep" } }
	}))
	fs.mkdir(path.join(pkg, "tests"))
	fs.write(path.join(pkg, "tests", "dummy.test.lua"), [[
		local test = require("lde-test")
		test.it("dummy passes", function() end)
	]])

	local ok, out = ldecli({ "test" }, pkg)
	test.truthy(ok, "lde test failed: " .. tostring(out)) ---@cast out -nil
	test.includes(out, "dummy passes")
	-- Install/build progress prints flush-left, which would break the
	-- indentation of the test results — it must be silenced during tests.
	test.falsy((out or ""):find("packages installed", 1, true),
		"install summary must not interleave with test results: " .. tostring(out))
	test.falsy((out or ""):find("QUIET%-MARKER", 1, true),
		"build.lua output must not interleave with test results: " .. tostring(out))

	fs.rmdir(tmpDir)
end)

test.it("errors in nested test modules point at the module, not the test file", function()
	local tmpDir = path.join(env.tmpdir(), "lde-test-nested-errors")
	fs.rmdir(tmpDir)
	fs.mkdir(tmpDir)

	-- The test file loads a nested module through a dynamic require; the module
	-- itself fails to require a missing sibling. The module's path under
	-- target/tests/ is long enough to hit LuaJIT's short_src truncation, which
	-- used to make the error get attributed to the test file instead.
	local pkg = path.join(tmpDir, "nested-err")
	fs.mkdir(pkg)
	fs.mkdir(path.join(pkg, "src"))
	fs.write(path.join(pkg, "src", "init.lua"), "return true")
	fs.write(path.join(pkg, "lde.json"), json.encode({ name = "nested-err", version = "0.1.0" }))

	fs.mkdir(path.join(pkg, "tests"))
	fs.mkdirAll(path.join(pkg, "tests", "deep", "nested", "modules"))
	fs.write(path.join(pkg, "tests", "loads.test.lua"), [[
		local test = require("lde-test")
		test.it("loads a page", function()
			local page = require("tests.deep.nested.modules.page-tilt")
			test.truthy(page)
		end)
	]])
	fs.write(path.join(pkg, "tests", "deep", "nested", "modules", "page-tilt.lua"), [[
		local button = require("tests.deep.nested.modules.buttonx-tilt")
		return { button = button }
	]])

	local ok, out = ldecli({ "test" }, pkg)
	test.falsy(ok, "the failing test must fail the run") ---@cast out -nil
	test.truthy(out:find("page%-tilt%.lua:%d+:", 1), "error must point at the nested module: " .. tostring(out))
	test.falsy(out:find("loads%.test%.lua:%d+:", 1), "error must not be attributed to the test file")

	fs.rmdir(tmpDir)
end)

test.it("lde test fails when no tests are found", function()
	local tmpDir = path.join(env.tmpdir(), "lde-test-none-found")
	fs.rmdir(tmpDir)
	fs.mkdir(tmpDir)

	-- No packages at all: errors with a hint (a typo'd tests/ dir must not
	-- silently pass).
	local ok, out = ldecli({ "test" }, tmpDir)
	test.falsy(ok, "lde test with no packages must fail")
	test.includes(out or "", "No packages with tests found")

	-- A package whose tests/ dir is empty: errors.
	local emptyPkg = path.join(tmpDir, "empty-tests")
	fs.mkdir(emptyPkg)
	fs.mkdir(path.join(emptyPkg, "src"))
	fs.mkdir(path.join(emptyPkg, "tests"))
	fs.write(path.join(emptyPkg, "src", "init.lua"), "return true")
	fs.write(path.join(emptyPkg, "lde.json"), json.encode({ name = "empty-tests", version = "0.1.0" }))

	ok, out = ldecli({ "test" }, emptyPkg)
	test.falsy(ok, "lde test with an empty tests/ dir must fail")
	test.includes(out or "", "No tests found in")

	-- A filter that matches no file: errors.
	local withTests = path.join(tmpDir, "with-tests")
	fs.mkdir(withTests)
	fs.mkdir(path.join(withTests, "src"))
	fs.mkdir(path.join(withTests, "tests"))
	fs.write(path.join(withTests, "src", "init.lua"), "return true")
	fs.write(path.join(withTests, "lde.json"), json.encode({ name = "with-tests", version = "0.1.0" }))
	fs.write(path.join(withTests, "tests", "a.test.lua"), 'local test = require("lde-test")\ntest.it("passes", function() end)')

	ok, out = ldecli({ "test", "--", "nope.test.lua" }, withTests)
	test.falsy(ok, "a filter matching nothing must fail")
	test.includes(out or "", "No test files match")

	-- A matching filter still passes.
	ok, out = ldecli({ "test", "--", "a.test.lua" }, withTests)
	test.truthy(ok, "a matching filter must pass: " .. tostring(out))

	fs.rmdir(tmpDir)
end)

test.it("--tree overrides the global lde directory", function()
	local tmpTree = path.join(env.tmpdir(), "lde-tree-test")
	fs.rmdir(tmpTree)

	ldecli { "--tree", tmpTree, "--version" }

	test.truthy(fs.exists(tmpTree))
	test.truthy(fs.exists(path.join(tmpTree, "git")))
end)

test.it("lde -v prints the version like --version", function()
	local okV, outV = ldecli { "-v" }
	local okLong, outLong = ldecli { "--version" }

	test.truthy(okV)
	test.truthy(okLong)
	test.truthy(outV and #outV > 0)
	test.equal(outV, outLong)
end)

test.it("lde -v combines with --tree like --version does", function()
	local tmpTree = path.join(env.tmpdir(), "lde-v-tree-test")
	fs.rmdir(tmpTree)

	local ok, out = ldecli { "-v", "--tree", tmpTree }
	test.truthy(ok)
	test.truthy(out and #out > 0)
	test.truthy(fs.exists(tmpTree))
	test.truthy(fs.exists(path.join(tmpTree, "git")))

	fs.rmdir(tmpTree)
end)

test.it("-C changes the working directory before loose-file resolution", function()
	local tmpDir = path.join(env.tmpdir(), "lde-cli-cwd-short")
	local pkgDir = path.join(tmpDir, "pkg")
	fs.rmdir(tmpDir)
	fs.mkdir(tmpDir)
	fs.mkdir(pkgDir)
	fs.write(path.join(pkgDir, "hello.lua"), 'io.write("cwd-short")')

	local ok, out = ldecli({ "-C", "pkg", "hello.lua" }, tmpDir)
	test.truthy(ok) ---@cast out -nil
	test.includes(out, "cwd-short")

	fs.rmdir(tmpDir)
end)

test.it("--cwd changes the working directory before package resolution", function()
	local tmpDir = path.join(env.tmpdir(), "lde-cli-cwd-long")
	local pkgDir = path.join(tmpDir, "pkg")
	fs.rmdir(tmpDir)
	fs.mkdir(tmpDir)
	fs.mkdir(pkgDir)
	fs.mkdir(path.join(pkgDir, "src"))
	fs.write(path.join(pkgDir, "src", "init.lua"), 'io.write("cwd-long")')
	fs.write(path.join(pkgDir, "lde.json"), json.encode({
		name = "cwd-long",
		version = "0.1.0"
	}))

	local ok, out = ldecli({ "--cwd", "pkg", "run" }, tmpDir)
	test.truthy(ok) ---@cast out -nil
	test.includes(out, "cwd-long")

	fs.rmdir(tmpDir)
end)

test.it("--cwd errors when the target directory does not exist", function()
	local tmpDir = path.join(env.tmpdir(), "lde-cli-cwd-missing")
	fs.rmdir(tmpDir)
	fs.mkdir(tmpDir)

	local ok, out = ldecli({ "--cwd", "missing", "--version" }, tmpDir)
	test.falsy(ok) ---@cast out -nil
	test.includes(out, "Directory does not exist")

	fs.rmdir(tmpDir)
end)

test.it("lde <script> <args> passes positional args to the script", function()
	local script = path.join(env.tmpdir(), "lde-argtest.lua")
	fs.write(script, 'io.write(arg[1] .. " " .. arg[2])')

	local ok, out = ldecli { script, "hello", "world" }
	test.truthy(ok) ---@cast out -nil
	test.includes(out, "hello world")
end)

test.it("lde <script> receives arg[0] as the script path", function()
	local script = path.join(env.tmpdir(), "lde-arg0test.lua")
	fs.write(script, "io.write(arg[0])")

	local ok, out = ldecli { script }
	test.truthy(ok) ---@cast out -nil
	test.includes(out, script)
end)

test.it("lde --lua <script> passes all positional args to the script", function()
	-- Regression: the first positional arg used to be swallowed as the CLI
	-- command name, so `lde --lua build-aux/luke install --quiet ...` ran
	-- luke without its `install` target and installed nothing.
	local script = path.join(env.tmpdir(), "lde-lua-argtest.lua")
	fs.write(script, 'io.write(table.concat(arg, "|"))')

	local ok, out = ldecli { "--lua", script, "install", "--quiet", "FOO=bar" }
	test.truthy(ok) ---@cast out -nil
	test.includes(out, "install|--quiet|FOO=bar")
end)

test.it("lde --lua runs -e chunks before the script in the same state", function()
	-- Test harnesses shell out through the lde binary as their Lua interpreter
	-- (e.g. a luacov prelude before a luarocks CLI run) and rely on the chunk's
	-- side effects being visible to the script.
	local script = path.join(env.tmpdir(), "lde-lua-echain.lua")
	fs.write(script, "io.write(marker)")

	local ok, out = ldecli { "--lua", "-e", "marker = 'chained'", script }
	test.truthy(ok) ---@cast out -nil
	test.includes(out, "chained")
end)

test.it("lde --lua supports multiple -e chunks", function()
	local ok, out = ldecli { "--lua", "-e", "io.write('a')", "-e", "io.write('b')" }
	test.truthy(ok) ---@cast out -nil
	test.includes(out, "ab")
end)

test.it("lde --lua rebuilds arg for the script after -e chunks", function()
	local script = path.join(env.tmpdir(), "lde-lua-eargs.lua")
	fs.write(script, "io.write(arg[0] .. '|' .. table.concat(arg, '|'))")

	local ok, out = ldecli { "--lua", "-e", "x = 1", script, "a", "b" }
	test.truthy(ok) ---@cast out -nil
	test.includes(out, script .. "|a|b")
end)

test.it("lde --lua -i enters an interactive REPL", function()
	-- The REPL reads stdin; without explicit stdin the child inherits the test
	-- runner's stdin and blocks forever when that's a live terminal/pipe, so
	-- close it immediately (empty write + EOF) to prove the prompt prints and
	-- the REPL loop terminates.
	local ok, out = ldecli({ "--lua", "-e", "io.write('pre')", "-i" }, nil, { stdin = "" })
	test.truthy(ok) ---@cast out -nil
	test.includes(out, "pre")
	test.includes(out, ">")
end)
