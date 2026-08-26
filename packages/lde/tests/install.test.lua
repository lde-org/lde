local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")
local process = require("process")

local ldecli = require("tests.lib.ldecli")

local tmpBase = path.join(env.tmpdir(), "lde-install-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

local ldeBinDir = path.dirname(assert(env.execPath()))

--- Run a tool wrapper with the lde binary dir prepended to PATH (the wrapper
--- execs `lde x ...`), returning exit code + merged output. The wrapper is
--- spawned directly on every platform — Windows CreateProcess routes .cmd
--- files through cmd.exe itself, and an explicit `cmd /c` breaks on arguments
--- that start with a drive letter ("C:\...").
---@param wrapperPath string
---@param args string[]
---@return number?, string?
local function runTool(wrapperPath, args)
	local sep = jit.os == "Windows" and ";" or ":"
	local code, stdout, stderr = process.exec(wrapperPath, args, {
		env = { PATH = ldeBinDir .. sep .. (os.getenv("PATH") or "") }
	})
	return code, (stdout or "") .. (stderr or "")
end

--- Path of the wrapper writeWrapper produces for a tool: a .cmd on Windows.
---@param treeDir string
---@param toolName string
---@return string
local function wrapperPath(treeDir, toolName)
	return path.join(treeDir, "tools", jit.os == "Windows" and (toolName .. ".cmd") or toolName)
end

--- A local git repo usable as an offline `--git` install source.
---@param name string
---@return string repoDir
local function makeLocalGitRepo(name)
	local repoDir = path.join(tmpBase, name .. "-repo")
	fs.rmdir(repoDir)
	fs.mkdir(repoDir)
	fs.mkdir(path.join(repoDir, "src"))
	fs.write(path.join(repoDir, "src", "init.lua"), 'io.write(arg[1] or "noarg")')
	fs.write(path.join(repoDir, "lde.json"), json.encode({
		name = name,
		version = "0.1.0",
		dependencies = {}
	}))

	assert(process.exec("git", { "init", "-q" }, { cwd = repoDir }), "git init failed")
	process.exec("git", { "add", "-A" }, { cwd = repoDir })
	local code = process.exec(
		"git", { "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init" },
		{ cwd = repoDir })
	assert(code == 0, "git commit failed: " .. tostring(code))
	return repoDir
end

local function makeProject(name)
	local dir = path.join(tmpBase, name)
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), "")
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = name,
		version = "0.1.0",
		dependencies = {}
	}))
	return dir
end

test.it("reinstalls src.rock correctly after tar cache and target are cleared (lde.lock retained)", function()
	local dir = makeProject("srcrock-reinstall-test")
	fs.write(path.join(dir, "src", "init.lua"), 'print(require("socket"))')

	-- Scope the cache clear to a throwaway --tree so the test never wipes the
	-- shared ~/.lde cache. The suite's other tests (e.g. the Teal/Moonscript
	-- fixtures) rely on the real cache staying warm — deleting it mid-suite
	-- forces them to re-download compilers from the network.
	local treeDir = path.join(tmpBase, "srcrock-tree")
	fs.rmdir(treeDir)

	local ok, out = ldecli({ "--tree", treeDir, "add", "rocks:luasocket" }, dir)
	test.truthy(ok, "lde add failed: " .. tostring(out))

	fs.rmdir(path.join(treeDir, "tar"))
	fs.rmdir(path.join(dir, "target"))

	ok, out = ldecli({ "--tree", treeDir, "run" }, dir)
	test.truthy(ok, "lde run failed after cache clear: " .. tostring(out))
end)

--
-- lde install: tools from --path / --git / rocks:, plus uninstall
--

	test.skipIf(env.var("ANDROID_ROOT") ~= nil)("install --path writes a wrapper and the tool runs with args", function()
	local toolDir = path.join(tmpBase, "mytool")
	fs.mkdir(toolDir)
	fs.mkdir(path.join(toolDir, "src"))
	fs.write(path.join(toolDir, "src", "main.lua"), 'io.write("path-tool:" .. (arg[1] or "?"))')
	-- target/<name> is a symlink to src/ for packages without a build.lua, so
	-- the bin path is relative to src/ ("main.lua", not "src/main.lua").
	fs.write(path.join(toolDir, "lde.json"), json.encode({
		name = "mytool",
		version = "0.1.0",
		bin = "main.lua",
		dependencies = {}
	}))

	local treeDir = path.join(tmpBase, "install-path-tree")
	fs.rmdir(treeDir)

	local ok, out = ldecli({ "--tree", treeDir, "install", "mytool", "--path", toolDir })
	test.truthy(ok, "lde install --path failed: " .. tostring(out))
	test.includes(out or "", "Installed tool")

	local wrapper = wrapperPath(treeDir, "mytool")
	test.truthy(fs.exists(wrapper), "wrapper not written")

	local code, runOut = runTool(wrapper, { "hello" })
	test.truthy(code == 0, "tool run failed: " .. tostring(runOut))
	test.includes(runOut or "", "path-tool:hello")
end)

-- Windows: Presumably from some issue with git
test.skipIf(jit.os == "Windows" or env.var("ANDROID_ROOT") ~= nil)("install --git clones and wraps a tool from a local repo", function()
	local repoDir = makeLocalGitRepo("gittool")
	local treeDir = path.join(tmpBase, "install-git-tree")
	fs.rmdir(treeDir)

	local ok, out = ldecli({ "--tree", treeDir, "install", "gittool", "--git", repoDir })
	test.truthy(ok, "lde install --git failed: " .. tostring(out))
	test.includes(out or "", "Installed tool")

	local wrapper = wrapperPath(treeDir, "gittool")
	test.truthy(fs.exists(wrapper), "wrapper not written")

	local code, runOut = runTool(wrapper, { "fromgit" })
	test.truthy(code == 0, "tool run failed: " .. tostring(runOut))
	test.includes(runOut or "", "fromgit")
end)

test.it("uninstall removes the tool wrapper", function()
	local toolDir = path.join(tmpBase, "rmtool")
	fs.mkdir(toolDir)
	fs.mkdir(path.join(toolDir, "src"))
	fs.write(path.join(toolDir, "src", "init.lua"), 'io.write("rmtool")')
	fs.write(path.join(toolDir, "lde.json"), json.encode({
		name = "rmtool",
		version = "0.1.0",
		dependencies = {}
	}))

	local treeDir = path.join(tmpBase, "install-rm-tree")
	fs.rmdir(treeDir)

	local ok, out = ldecli({ "--tree", treeDir, "install", "rmtool", "--path", toolDir })
	test.truthy(ok, "lde install failed: " .. tostring(out))
	local wrapper = wrapperPath(treeDir, "rmtool")
	test.truthy(fs.exists(wrapper))

	local ok2, out2 = ldecli({ "--tree", treeDir, "uninstall", "rmtool" })
	test.truthy(ok2, "lde uninstall failed: " .. tostring(out2))
	test.includes(out2 or "", "Uninstalled tool")
	test.falsy(fs.exists(wrapper), "wrapper should be removed")

	-- Uninstalling again reports it as not installed.
	local ok3, out3 = ldecli({ "--tree", treeDir, "uninstall", "rmtool" })
	test.truthy(ok3)
	test.includes(out3 or "", "not installed")
end)

test.skipIf(env.var("ANDROID_ROOT") ~= nil)("install rocks:<name> installs a tool with a bin and the wrapper compiles a file", function()
	local treeDir = path.join(tmpBase, "install-rocks-tree")
	fs.rmdir(treeDir)

	local ok, out = ldecli({ "--tree", treeDir, "install", "rocks:moonscript" })
	assert(ok, "lde install rocks:moonscript failed: " .. tostring(out))
	test.includes(out or "", "Installed tool")

	local wrapper = wrapperPath(treeDir, "moonscript")
	assert(fs.exists(wrapper), "wrapper not written")

	-- The moon bin takes a .moon file; compile-and-run it through the wrapper.
	local moonFile = path.join(tmpBase, "hello.moon")
	fs.write(moonFile, 'print "hello from moon"\n')
	local code, runOut = runTool(wrapper, { moonFile })
	assert(code == 0, "moon run failed: " .. tostring(runOut))
	test.includes(runOut or "", "hello from moon")
end)

--
-- Rockspec packages as path dependencies
--

test.it("runs code that requires a rockspec package installed as a path dep", function()
	local rockDir = path.join(tmpBase, "useful-rock")
	fs.mkdir(rockDir)
	fs.mkdir(path.join(rockDir, "src"))
	fs.write(path.join(rockDir, "src", "util.lua"), 'return { greet = function(n) return "hi " .. n end }')
	fs.write(path.join(rockDir, "useful-rock-1.0-1.rockspec"), [[
package = "useful-rock"
version = "1.0-1"
source = { url = "https://example.com" }
build = { type = "builtin", modules = { ["useful-rock"] = "src/util.lua" } }
]])

	local appDir = path.join(tmpBase, "rock-consumer-cli")
	fs.mkdir(appDir)
	fs.mkdir(path.join(appDir, "src"))
	fs.write(path.join(appDir, "src", "init.lua"), [[
local rock = require("useful-rock")
print(rock.greet("cli"))
]])
	fs.write(path.join(appDir, "lde.json"), json.encode({
		name = "rock-consumer-cli",
		version = "0.1.0",
		dependencies = {
			["useful-rock"] = { path = "../useful-rock" }
		}
	}))

	local ok, out = ldecli({ "run" }, appDir)
	test.truthy(ok, "lde run with rockspec dep failed: " .. tostring(out))
	test.includes(out or "", "hi cli")
end)

--
-- Compact install output: build.lua stdout is hidden by default, shown with --verbose
--

test.it("build.lua output is hidden by default and streamed with --verbose", function()
	-- A path dep whose build.lua writes a marker to stdout. In compact mode
	-- the marker must never reach the terminal; with --verbose it must.
	local depDir = path.join(tmpBase, "noisy-dep")
	fs.rmdir(depDir)
	fs.mkdir(depDir)
	fs.mkdir(path.join(depDir, "src"))
	fs.write(path.join(depDir, "src", "init.lua"), 'return {}')
	fs.write(path.join(depDir, "lde.json"), json.encode({
		name = "noisy-dep",
		version = "0.1.0",
		dependencies = {}
	}))
	fs.write(path.join(depDir, "build.lua"), [[
local build = require("lde-build")
build:sh("echo NOISY-MARKER")
build:write("init.lua", "return {}")
]])

	local appDir = makeProject("noisy-app")
	fs.write(path.join(appDir, "src", "init.lua"), 'print("app-ran")')
	fs.write(path.join(appDir, "lde.json"), json.encode({
		name = "noisy-app",
		version = "0.1.0",
		dependencies = {
			["noisy-dep"] = { path = "../noisy-dep" }
		}
	}))

	local ok, out = ldecli({ "run" }, appDir)
	test.truthy(ok, "lde run failed: " .. tostring(out))
	test.includes(out or "", "app-ran")
	test.falsy((out or ""):find("NOISY-MARKER", 1, true),
		"build.lua output must be hidden by default: " .. tostring(out))
	-- Compact install output is a single summary line — no per-dependency
	-- check marks in the scrollback.
	test.includes(out or "", "packages installed")
	test.falsy((out or ""):find("✓ noisy%-dep", 1, true),
		"no per-dependency lines in compact mode: " .. tostring(out))

	-- Touch the dep's source so the stamp is stale and the build re-runs.
	fs.write(path.join(depDir, "src", "init.lua"), 'return {}\n-- touched\n')

	local ok2, out2 = ldecli({ "--verbose", "run" }, appDir)
	test.truthy(ok2, "lde run --verbose failed: " .. tostring(out2))
	test.includes(out2 or "", "NOISY-MARKER", "--verbose must stream build.lua output")
end)
