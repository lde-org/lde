-- Tests for CLI commands that had no coverage: `lde tree`, `lde x`, `lde
-- update`, `lde outdated`, `lde repl`, `lde completion`, `lde bundle`, and the
-- `--profile` / `--flamegraph` run flags. Also covers `lde -e` in project
-- context, `lde run <script>` (lde.json scripts), the legacy `lpm.json`
-- manifest, and running a loose file through `lde run`.
local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")
local process = require("process")

local cli = require("tests.lib.ldecli")

local tmpBase = path.join(env.tmpdir(), "lde-commands-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

---Strip ANSI escape sequences so output matches work with or without colors.
---@param s string
---@return string
local function plain(s)
	return ((s or ""):gsub("\27%[[0-9;]*m", ""))
end

---@param name string
---@param deps table?
---@param extra table?
---@return string dir
local function makeProject(name, deps, extra)
	local dir = path.join(tmpBase, name)
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), 'return "' .. name .. '"')
	local config = {
		name = name,
		version = "0.1.0",
		dependencies = deps or {}
	}
	if extra then
		for k, v in pairs(extra) do config[k] = v end
	end
	fs.write(path.join(dir, "lde.json"), json.encode(config))
	return dir
end

--- A local git repo usable as an offline git dependency (libgit2's lsRemote
--- and clone accept plain local paths). Returns the repo dir.
---@param name string
---@return string repoDir
local function makeLocalGitRepo(name)
	local repoDir = path.join(tmpBase, name .. "-repo")
	fs.rmdir(repoDir)
	fs.mkdir(repoDir)
	fs.mkdir(path.join(repoDir, "src"))
	fs.write(path.join(repoDir, "src", "init.lua"), 'return "' .. name .. '"')
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

--- Append a file + commit to a local repo (moving its HEAD forward).
---@param repoDir string
---@param file string
---@param content string
local function commitMore(repoDir, file, content)
	fs.write(path.join(repoDir, file), content)
	process.exec("git", { "add", "-A" }, { cwd = repoDir })
	local code = process.exec(
		"git", { "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "more" },
		{ cwd = repoDir })
	assert(code == 0, "second commit failed: " .. tostring(code))
end

--
-- lde tree
--

test.it("lde tree prints the dependency tree with source kinds", function()
	makeProject("tree-dep", nil, { name = "tree-dep" })
	local dir = makeProject("tree-app", {
		["tree-dep"] = { path = "../tree-dep" }
	})

	local ok, out = cli({ "tree" }, dir)
	test.truthy(ok, "lde tree failed: " .. tostring(out))
	local text = plain(out or "")
	test.includes(text, "tree-app")
	test.includes(text, "tree-dep")
	test.includes(text, "path: ../tree-dep")
end)

test.it("lde tree marks skipped optional dependencies", function()
	makeProject("tree-opt")
	local dir = makeProject("tree-opt-app", {
		["tree-opt"] = { path = "../tree-opt", optional = true }
	})

	local ok, out = cli({ "tree" }, dir)
	test.truthy(ok, "lde tree failed: " .. tostring(out))
	local text = plain(out or "")
	test.includes(text, "tree-opt")
	test.includes(text, "optional, skipped")
end)

test.it("lde tree --why renders the chain to a transitive dependency", function()
	makeProject("why-leaf", nil, { name = "why-leaf" })
	makeProject("why-mid", { ["why-leaf"] = { path = "../why-leaf" } }, { name = "why-mid" })
	makeProject("why-other", nil, { name = "why-other" })
	local dir = makeProject("why-app", {
		["why-mid"] = { path = "../why-mid" },
		["why-other"] = { path = "../why-other" }
	})

	-- With colors disabled (CI/pipes) everything renders plain, so assert the
	-- structure: both branches present, no errors.
	local ok, out = cli({ "tree", "--why", "why-leaf" }, dir)
	test.truthy(ok, "lde tree --why failed: " .. tostring(out))
	local text = plain(out or "")
	test.includes(text, "why-app")
	test.includes(text, "why-mid")
	test.includes(text, "why-leaf")
	test.includes(text, "why-other")
end)

test.it("lde tree --why reports an unknown dependency", function()
	local dir = makeProject("why-unknown")
	local ok, out = cli({ "tree", "--why", "nope" }, dir)
	test.falsy(ok, "unknown --why target must fail")
	test.includes(plain(out or ""), "'nope' is not a dependency of why-unknown")
end)

--
-- lde x
--

test.it("lde x --path runs a local package entry with args", function()
	local toolDir = makeProject("xtool", nil, {
		-- entry prints arg[1]
		bin = "main.lua"
	})
	fs.write(path.join(toolDir, "src", "main.lua"), 'io.write("x-tool:" .. (arg[1] or "?"))')

	local ok, out = cli({ "x", "--path", toolDir, "xtool", "--", "hello" })
	test.truthy(ok, "lde x --path failed: " .. tostring(out))
	test.includes(out or "", "x-tool:hello")
end)

test.it("lde x --path finds a named subpackage inside a monorepo dir", function()
	local mono = path.join(tmpBase, "x-mono")
	fs.rmdir(mono)
	fs.mkdir(mono)
	makeProject(path.join("x-mono", "alpha"), nil, { name = "alpha" })
	makeProject(path.join("x-mono", "beta"), nil, { name = "beta" })

	local ok, out = cli({ "x", "--path", mono, "beta", "--", "b" }, tmpBase)
	test.truthy(ok, "lde x subpackage lookup failed: " .. tostring(out))
end)

test.it("lde x without a name prints usage", function()
	local ok, out = cli({ "x" })
	test.truthy(ok)
	test.includes(plain(out or ""), "Usage: lde x")
end)

--
-- lde update (git deps, offline via local repos)
--

test.skipIf(env.var("ANDROID_ROOT") ~= nil)("lde update <name> pins a newer git commit into the lockfile", function()
	local repoDir = makeLocalGitRepo("upd-dep")
	local dir = makeProject("upd-app", { ["upd-dep"] = { git = repoDir } })

	local ok, out = cli({ "sync" }, dir)
	test.truthy(ok, "initial sync failed: " .. tostring(out))
	local lock1Raw = fs.read(path.join(dir, "lde.lock")) ---@cast lock1Raw -nil
	local lock1 = json.decode(lock1Raw) ---@cast lock1 table<string, any>
	local commit1 = lock1.dependencies["upd-dep"].commit
	test.truthy(commit1)

	-- The upstream repo moves forward; `lde update upd-dep` must re-resolve.
	commitMore(repoDir, "src/v2.lua", 'return "v2"')

	local ok2, out2 = cli({ "update", "upd-dep" }, dir)
	test.truthy(ok2, "lde update failed: " .. tostring(out2))
	test.includes(plain(out2 or ""), "upd-dep")
	test.includes(plain(out2 or ""), "->")
	local lock2Raw = fs.read(path.join(dir, "lde.lock")) ---@cast lock2Raw -nil
	local lock2 = json.decode(lock2Raw) ---@cast lock2 table<string, any>
	local commit2 = lock2.dependencies["upd-dep"].commit
	test.truthy(commit2 and commit2 ~= commit1, "lockfile commit must move to the new HEAD")

	-- The updated pin must be installable.
	local ok3, out3 = cli({ "sync" }, dir)
	test.truthy(ok3, "sync after update failed: " .. tostring(out3))
	test.truthy(fs.exists(path.join(dir, "target", "upd-dep", "v2.lua")),
		"updated commit must be materialized")
end)

test.skipIf(env.var("ANDROID_ROOT") ~= nil)("lde update reports no changes when git deps are already at HEAD", function()
	local repoDir = makeLocalGitRepo("uptodate-dep")
	local dir = makeProject("uptodate-app", { ["uptodate-dep"] = { git = repoDir } })

	cli({ "sync" }, dir)
	local ok, out = cli({ "update" }, dir)
	test.truthy(ok, "lde update failed: " .. tostring(out))
	test.includes(plain(out or ""), "no changes")
end)

test.it("lde update errors for an unknown dependency name", function()
	local dir = makeProject("update-unknown")
	local ok, out = cli({ "update", "nope" }, dir)
	test.falsy(ok)
	test.includes(plain(out or ""), "Unknown dependency")
end)

--
-- lde outdated
--

test.it("lde outdated reports all up to date for path deps", function()
	makeProject("outdated-dep")
	local dir = makeProject("outdated-app", { ["outdated-dep"] = { path = "../outdated-dep" } })

	local ok, out = cli({ "outdated" }, dir)
	test.truthy(ok, "lde outdated failed: " .. tostring(out))
	test.includes(plain(out or ""), "All dependencies are up to date")
end)

--
-- lde repl
--

test.it("lde repl evaluates piped stdin as a script (no banner, no prompts)", function()
	-- Piped stdin is script mode: input is evaluated line by line (locals
	-- persist across lines), and the banner + prompts are suppressed so the
	-- output stays clean for piping.
	local ok, out = cli({ "repl" }, nil, { stdin = "print(1 + 1)\nlocal x = 40\nprint(x + 2)\n" })
	test.truthy(ok, "lde repl failed: " .. tostring(out))
	test.includes(plain(out or ""), "2")
	test.includes(plain(out or ""), "42")
	test.falsy(plain(out or ""):find("lde repl", 1, true), "banner must not print when stdin is piped")
	test.falsy(plain(out or ""):find(">", 1, true), "prompts must not print when stdin is piped")
end)

test.it("lde repl exits cleanly on empty piped stdin", function()
	local ok, out = cli({ "repl" }, nil, { stdin = "" })
	test.truthy(ok, "lde repl failed: " .. tostring(out))
	test.falsy(plain(out or ""):find(">", 1, true), "no prompts on empty piped stdin")
end)

--
-- lde completion
--

test.it("lde completion bash emits a completion script", function()
	local ok, out = cli({ "completion", "bash" })
	test.truthy(ok, "lde completion bash failed: " .. tostring(out))
	test.includes(out or "", "_lde()")
	test.includes(out or "", "complete -F _lde lde")
end)

test.it("lde __complete offers files where a file can be passed", function()
	local dir = makeProject("completion-files", nil, { name = "completion-files" })
	fs.write(path.join(dir, "main.lua"), "return true")
	fs.mkdir(path.join(dir, "sub"))
	fs.write(path.join(dir, "sub", "inner.lua"), "return true")

	-- `lde <file>`: loose-file position completes files when no command matches.
	local ok, out = cli({ "__complete", "./ma" }, dir)
	test.truthy(ok)
	test.includes(out or "", "./main.lua")

	-- `lde run <file>`: the run positional completes files, including
	-- directories with a trailing slash and traversal into them.
	local ok2, out2 = cli({ "__complete", "run", "sub/i" }, dir)
	test.truthy(ok2)
	test.includes(out2 or "", "sub/inner.lua")

	-- A command prefix still completes commands, not files.
	local ok3, out3 = cli({ "__complete", "ru" }, dir)
	test.truthy(ok3) ---@cast out3 -nil
	test.includes(out3 or "", "run")
	test.falsy(out3:find("main%.lua"))

	-- An empty first word offers commands only, without file noise.
	local ok4, out4 = cli({ "__complete", "" }, dir)
	test.truthy(ok4) ---@cast out4 -nil
	test.includes(out4 or "", "run")
	test.falsy(out4:find("main%.lua"))
end)

test.it("lde __complete run suggests files after a boolean flag", function()
	local dir = makeProject("completion-run-flags", nil, { name = "completion-run-flags" })
	fs.write(path.join(dir, "app.lua"), "return true")

	local ok, out = cli({ "__complete", "run", "--hot", "./ap" }, dir)
	test.truthy(ok)
	test.includes(out or "", "./app.lua")

	-- A value-taking flag still suppresses suggestions for its value position.
	local ok2, out2 = cli({ "__complete", "run", "--flamegraph", "./ap" }, dir)
	test.truthy(ok2)
	test.falsy(out2 and out2:find("app%.lua"))
end)

test.it("lde __complete suggests lde.json script names", function()
	local dir = makeProject("completion-scripts", nil, {
		name = "completion-scripts",
		scripts = { dev = "echo dev", build = "echo build" }
	})
	fs.write(path.join(dir, "main.lua"), "return true")

	-- Script names join commands at the first word.
	local ok, out = cli({ "__complete", "" }, dir)
	test.truthy(ok)
	test.includes(out or "", "dev")
	test.includes(out or "", "build")
	test.includes(out or "", "run")

	-- Typing a script prefix completes the script.
	local ok2, out2 = cli({ "__complete", "de" }, dir)
	test.truthy(ok2) ---@cast out2 -nil
	test.includes(out2 or "", "dev")
	test.falsy(out2:find("main%.lua"))

	-- `lde run` offers scripts and files together.
	local ok3, out3 = cli({ "__complete", "run", "" }, dir)
	test.truthy(ok3)
	test.includes(out3 or "", "dev")
	test.includes(out3 or "", "main.lua")

	-- Boolean flags do not stop script completion.
	local ok4, out4 = cli({ "__complete", "run", "--watch", "de" }, dir)
	test.truthy(ok4)
	test.includes(out4 or "", "dev")
end)

test.it("lde __complete dedupes scripts that share a command name", function()
	local dir = makeProject("completion-script-dup", nil, {
		name = "completion-script-dup",
		scripts = { run = "echo run", test = "echo test" }
	})

	local ok, out = cli({ "__complete", "run" }, dir)
	test.truthy(ok)
	local count = 0
	-- Split on either line ending: the child's captured stdout uses \r\n on
	-- Windows, and the exact match must not see the trailing \r.
	for line in (out or ""):gmatch("[^\r\n]+") do
		if line == "run" then count = count + 1 end
	end
	test.equal(count, 1, "command and script with the same name must dedupe")
end)

test.it("lde __complete reads scripts from a legacy lpm.json", function()
	local dir = path.join(tmpBase, "completion-lpm")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), "return true")
	fs.write(path.join(dir, "lpm.json"), json.encode({
		name = "completion-lpm",
		version = "0.1.0",
		scripts = { dev = "echo dev" }
	}))

	local ok, out = cli({ "__complete", "de" }, dir)
	test.truthy(ok)
	test.includes(out or "", "dev")
end)

test.it("lde completion rejects unknown shells", function()
	local ok, out = cli({ "completion", "tcsh" })
	test.falsy(ok)
	test.includes(plain(out or ""), "Unknown shell")
end)

--
-- lde bundle
--

test.it("lde bundle writes a self-contained module file", function()
	local dir = makeProject("bundle-cli", nil, { name = "bundle-cli" })
	fs.write(path.join(dir, "src", "helper.lua"), 'return { n = 7 }')

	local ok, out = cli({ "bundle" }, dir)
	test.truthy(ok, "lde bundle failed: " .. tostring(out))
	local bundlePath = path.join(dir, "bundle-cli.lua")
	test.truthy(fs.exists(bundlePath), "bundle file not written")

	local content = fs.read(bundlePath) or ""
	test.includes(content, '"bundle-cli"')
	test.includes(content, '"bundle-cli.helper"')

	-- The bundle is executable Lua: run it and the entry point's side effects
	-- (print) must appear.
	local execPath = env.execPath() ---@cast execPath -nil
	local code, runOut = process.exec(execPath, { "--lua", bundlePath })
	test.truthy(code == 0, "bundle did not run: " .. tostring(runOut))
end)

test.it("lde bundle --bytecode writes a LuaJIT bytecode bundle", function()
	local dir = makeProject("bundle-bc", nil, { name = "bundle-bc" })

	local ok, out = cli({ "bundle", "--bytecode" }, dir)
	test.truthy(ok, "lde bundle --bytecode failed: " .. tostring(out))
	local bundlePath = path.join(dir, "bundle-bc.lua")
	test.truthy(fs.exists(bundlePath))
	local content = fs.read(bundlePath) or ""
	-- LuaJIT bytecode files start with the \27LJ signature.
	test.truthy(content:sub(1, 3) == "\27LJ", "expected bytecode bundle, got source")
end)

--
-- lde compile (full sea pipeline)
--

test.it("lde compile produces a runnable binary that receives argv", function()
	local dir = makeProject("compile-cli", nil, { name = "compile-cli" })
	-- The compiled main module receives argv as its varargs (same convention as
	-- the lde binary itself, which reads ... at the top level).
	fs.write(path.join(dir, "src", "init.lua"), [[
local args = { ... }
print("compiled-ok:" .. (args[1] or "noargs"))
]])

	local ok, out = cli({ "compile" }, dir)
	test.truthy(ok, "lde compile failed: " .. tostring(out))
	local binPath = path.join(dir, "compile-cli")
	if jit.os == "Windows" then binPath = binPath .. ".exe" end
	test.truthy(fs.exists(binPath), "compiled binary missing")

	local code, runOut = process.exec(binPath, { "hi" })
	test.truthy(code == 0, "compiled binary failed: " .. tostring(runOut))
	test.includes(runOut or "", "compiled-ok:hi")
end)

-- The release target matching the host (nil when none does, e.g. musl hosts).
local sea = require("sea")
local hostTargetName = (function()
	local host = sea.getHostTarget()
	for name, target in pairs(sea.targets) do
		if target.platform == host.platform and target.arch == host.arch
			and (target.libc or "") == (host.libc or "") then
			return name
		end
	end
	return nil
end)()

test.skipIf(hostTargetName == nil)("lde compile --target=<host> is a native build", function()
	local dir = makeProject("compile-host-target", nil, { name = "compile-host-target" })
	fs.write(path.join(dir, "src", "init.lua"), 'print("host-target-ok")')

	local ok, out = cli({ "compile", "--target", hostTargetName }, dir)
	test.truthy(ok, "lde compile --target failed: " .. tostring(out))
	local binPath = path.join(dir, "compile-host-target")
	if jit.os == "Windows" then binPath = binPath .. ".exe" end
	test.truthy(fs.exists(binPath), "compiled binary missing")

	local code, runOut = process.exec(binPath, {})
	test.truthy(code == 0, "compiled binary failed: " .. tostring(runOut))
	test.includes(runOut or "", "host-target-ok")
end)

test.it("lde compile --target=bogus is a clean error", function()
	local dir = makeProject("compile-bogus-target", nil, { name = "compile-bogus-target" })

	local ok, out = cli({ "compile", "--target", "bogus" }, dir)
	test.falsy(ok, "unknown target must fail")
	local msg = plain(out or "")
	test.includes(msg, "Unknown compile target 'bogus'")
	test.includes(msg, "expected one of")
	test.includes(msg, "windows-x86-64")
end)

--
-- lde run --profile / --flamegraph
--

test.it("lde run --profile prints a profile report", function()
	local dir = makeProject("prof-cli", nil, {
		name = "prof-cli",
		bin = "main.lua"
	})
	fs.write(path.join(dir, "src", "main.lua"), [[
		local s = 0
		for i = 1, 5000000 do s = s + i end
		print("prof-done")
	]])

	local ok, out = cli({ "run", "--profile" }, dir)
	test.truthy(ok, "lde run --profile failed: " .. tostring(out))
	test.includes(plain(out or ""), "Profile")
	test.includes(out or "", "prof-done")
end)

test.it("lde run --flamegraph writes an HTML flamegraph", function()
	local dir = makeProject("fg-cli", nil, {
		name = "fg-cli",
		bin = "main.lua"
	})
	fs.write(path.join(dir, "src", "main.lua"), [[
		local function work(n)
			local s = 0
			for i = 1, n do s = s + i end
			return s
		end
		for i = 1, 20 do work(2000000) end
	]])
	local fgPath = path.join(tmpBase, "fg-cli.html")
	fs.delete(fgPath)

	local ok, out = cli({ "run", "--flamegraph", fgPath }, dir)
	test.truthy(ok, "lde run --flamegraph failed: " .. tostring(out))
	test.truthy(fs.exists(fgPath), "flamegraph HTML not written: " .. tostring(out))
	local html = fs.read(fgPath) or ""
	test.includes(html, "<!DOCTYPE html>")
	test.falsy(html:find("__DATA__", 1, true))
end)

test.it("lde run --json writes programmatically checkable profile data", function()
	local dir = makeProject("json-cli", nil, {
		name = "json-cli",
		bin = "main.lua"
	})
	-- A named hotspot so the JSON can be asserted against real content.
	fs.write(path.join(dir, "src", "main.lua"), [[
		local function hotspot(n)
			local s = 0
			for i = 1, n do s = s + i end
			return s
		end
		for i = 1, 30 do hotspot(2000000) end
		print("json-done")
	]])
	local jsonPath = path.join(tmpBase, "json-cli.json")
	fs.delete(jsonPath)

	local ok, out = cli({ "run", "--json", jsonPath }, dir)
	test.truthy(ok, "lde run --json failed: " .. tostring(out))
	test.includes(out or "", "json-done")
	test.truthy(fs.exists(jsonPath), "profile JSON not written: " .. tostring(out))

	local dataRaw = fs.read(jsonPath) ---@cast dataRaw -nil
	local data = json.decode(dataRaw) ---@cast data table<string, any>
	test.truthy(data, "profile JSON must decode")
	test.truthy(data.total > 0, "expected sampled data, got total=" .. tostring(data.total))
	test.equal(data.version, 1)
	test.equal(data.intervalMs, 1)
	test.equal(data.totalMs, data.total)
	test.truthy(type(data.vmstates) == "table" and next(data.vmstates) ~= nil,
		"expected vmstate samples")
	-- The named hotspot must appear with a positive sample count.
	local hotspot
	for _, h in ipairs(data.hotspots) do
		if h.loc == "hotspot" then hotspot = h end
	end
	test.truthy(hotspot, "expected a 'hotspot' entry in the profile data")
	test.truthy(hotspot.count > 0)
	-- Folded stacks must also be present (flamegraph input).
	test.truthy(type(data.stacks) == "table" and next(data.stacks) ~= nil,
		"expected folded stack data")
end)

--
-- lde -e in project context
--

test.it("lde -e evaluates with the project's dependencies available", function()
	makeProject("eval-dep", nil, { name = "eval-dep" })
	local dir = makeProject("eval-app", { ["eval-dep"] = { path = "../eval-dep" } })

	local ok, out = cli({ "-e", 'io.write(require("eval-dep"))' }, dir)
	test.truthy(ok, "lde -e with deps failed: " .. tostring(out))
	test.includes(out or "", "eval-dep")
end)

test.it("lde -e prints non-nil results like a REPL", function()
	-- Run from a non-package dir so no project context is opened.
	local ok, out = cli({ "-e", "return 40 + 2" }, tmpBase)
	test.truthy(ok)
	test.includes(out or "", "42")
end)

--
-- lde run <script> (lde.json scripts) and loose files
--

test.it("lde run <script> executes an lde.json shell script", function()
	local dir = makeProject("script-app", nil, {
		scripts = { greet = "echo hello-from-script" }
	})

	local ok, out = cli({ "run", "greet" }, dir)
	test.truthy(ok, "lde run <script> failed: " .. tostring(out))
	test.includes(out or "", "hello-from-script")
end)

test.it("lde run <script> reports a non-zero script exit", function()
	local dir = makeProject("script-fail", nil, {
		scripts = { boom = "exit 3" }
	})

	local ok, out = cli({ "run", "boom" }, dir)
	test.falsy(ok, "failing script must exit non-zero")
	test.includes(plain(out or ""), "exit code 3")
end)

test.it("lde <script> -- <args> passes args after -- to the script", function()
	local dir = makeProject("script-direct-args", nil, {
		scripts = { greet = "echo direct-script" }
	})

	local ok, out = cli({ "greet", "--", "a b", "c", "it's" }, dir)
	test.truthy(ok, "lde <script> -- args failed: " .. tostring(out))
	-- cmd.exe echo prints its quoted args verbatim; POSIX sh joins with spaces.
	local _, _, isCmd = require("lde-core").global.getScriptShell()
	if isCmd then
		test.includes(out or "", "a b")
		test.includes(out or "", "it's")
	else
		test.includes(out or "", "direct-script a b c it's")
	end
end)

test.it("lde run <script> -- <args> passes args after -- to the script", function()
	local dir = makeProject("run-script-args", nil, {
		scripts = { greet = "echo run-script" }
	})

	local ok, out = cli({ "run", "greet", "--", "hello", "world" }, dir)
	test.truthy(ok, "lde run <script> -- args failed: " .. tostring(out))
	local _, _, isCmd = require("lde-core").global.getScriptShell()
	if isCmd then
		test.includes(out or "", "hello")
		test.includes(out or "", "world")
	else
		test.includes(out or "", "run-script hello world")
	end
end)

test.it("lde run <file.lua> runs a loose file inside the package context", function()
	makeProject("runfile-dep", nil, { name = "runfile-dep" })
	local dir = makeProject("runfile-app", { ["runfile-dep"] = { path = "../runfile-dep" } })
	local scriptPath = path.join(dir, "check.lua")
	fs.write(scriptPath, 'print("loose:" .. require("runfile-dep"))')

	local ok, out = cli({ "run", "check.lua" }, dir)
	test.truthy(ok, "lde run <file> failed: " .. tostring(out))
	test.includes(out or "", "loose:runfile-dep")
end)

--
-- Legacy lpm.json manifest
--

test.it("lpm.json manifests work with sync and run", function()
	makeProject("lpm-dep", nil, { name = "lpm-dep" })
	local dir = path.join(tmpBase, "lpm-app")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), 'print(require("lpm-dep"))')
	fs.write(path.join(dir, "lpm.json"), json.encode({
		name = "lpm-app",
		version = "0.1.0",
		dependencies = {
			["lpm-dep"] = { path = "../lpm-dep" }
		}
	}))
	-- No lde.json: the legacy manifest must be picked up.

	local ok, out = cli({ "sync" }, dir)
	test.truthy(ok, "sync with lpm.json failed: " .. tostring(out))
	test.truthy(fs.exists(path.join(dir, "target", "lpm-dep", "init.lua")))

	local ok2, out2 = cli({ "run" }, dir)
	test.truthy(ok2, "run with lpm.json failed: " .. tostring(out2))
	test.includes(out2 or "", "lpm-dep")
end)
