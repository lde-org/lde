-- fuzzer/src/packages.lua
--
-- Package-content fuzzer: generates random projects (manifest, build.lua,
-- src/ files, lockfile) and runs lde commands against them. Everything is
-- hermetic: deps are local path/git deps only (no registry/network), HOME is
-- isolated, and each case gets a fresh project dir.

local fs = require("fs")
local path = require("path")
local json = require("json")
local ansi = require("ansi")
local runner = require("fuzzer.runner")

---@param rng fuzz.Rng
---@return string
local function randomName(rng)
	return rng.pick({
		"pkg-a", "ns/pkg-b", "PkgC", "tests", "a b", "", "123",
		"with-dash", "under_score", "日本語", "pkg.with.dots",
	})
end

---@param rng fuzz.Rng
---@return any
local function randomJunk(rng)
	local v = rng.pick({
		function() return rng.token(10) end,
		function() return rng.int(10000) end,
		function() return rng.chance(0.5) end,
		function() return { rng.token(5), rng.token(5) } end,
		function() return { [rng.token(5)] = rng.token(5) } end,
		function() return nil end,
	})
	if type(v) == "function" then return v() end
	return v
end

--- Generate a dependency table. Only path/git kinds (offline-safe); dep dirs
--- are the real scratch deps most of the time so installs succeed.
---@param rng fuzz.Rng
---@param ctx { deps: string[], gitRepo: string }
---@return table
local function randomDeps(rng, ctx)
	local deps = {}
	for _ = 1, rng.int(3) do
		local alias = randomName(rng)
		local kind = rng.int(10)
		local info
		if kind < 5 then
			-- Real local path dep (installs cleanly).
			info = { path = path.join("../deps", rng.pick({ "dep-a", "dep-b" })) }
		elseif kind < 6 then
			-- Local git dep (offline clone).
			info = { git = ctx.gitRepo }
		elseif kind < 7 then
			info = { path = rng.token(20), optional = rng.chance(0.5) }
		elseif kind < 8 then
			-- Dep as a plain string (invalid shape) or junk value.
			deps[alias] = rng.chance(0.5) and "../deps/dep-a" or randomJunk(rng)
			goto continue
		elseif kind < 9 then
			info = { path = path.join("../deps", rng.pick({ "dep-a", "dep-b" })), features = { rng.token(8) } }
		else
			info = { git = "https://nonexistent.invalid/repo.git" }
		end
		deps[alias] = info
		::continue::
	end
	return deps
end

---@param rng fuzz.Rng
---@return table
local function randomScripts(rng)
	local scripts = {}
	for _, name in ipairs({ "run", "build", "test", "hello", rng.token(10), "" }) do
		if rng.chance(0.4) then
			scripts[name] = rng.pick({
				"echo hi", "exit 1", "false", "true", "cd /nonexistent",
				"echo " .. rng.token(10), rng.token(20),
			})
		end
	end
	return scripts
end

---@param rng fuzz.Rng
---@param ctx { deps: string[], gitRepo: string }
---@return string # raw lde.json content
local function generateManifest(rng, ctx)
	local mode = rng.int(10)
	if mode < 4 then
		-- Valid JSON from a random structure.
		local t = {
			name = randomName(rng),
			version = rng.pick({ "0.1.0", "1.0.0", "2.0.0-beta.1", "0.0.0" }),
		}
		if rng.chance(0.1) then t.name = nil end
		if rng.chance(0.1) then t.version = nil end
		if rng.chance(0.6) then t.dependencies = randomDeps(rng, ctx) end
		if rng.chance(0.25) then t.devDependencies = randomDeps(rng, ctx) end
		if rng.chance(0.3) then t.scripts = randomScripts(rng) end
		if rng.chance(0.2) then
			t.features = { linux = { "dep-a" }, windows = { rng.token(8) } }
		end
		if rng.chance(0.3) then t[rng.token(10)] = randomJunk(rng) end
		return json.encode(t)
	elseif mode < 6 then
		-- Random junk structure (numbers, arrays, nesting).
		local junk = {}
		for _ = 1, rng.int(4) do junk[randomName(rng)] = randomJunk(rng) end
		if rng.chance(0.5) then junk.dependencies = randomDeps(rng, ctx) end
		return json.encode(junk)
	elseif mode < 9 then
		-- Invalid JSON / garbage bytes.
		return rng.pick({
			"", "{", "}{", "not json", '{"name":', "{{\"a\":1}", "null", "42",
			"{\"name\": \"x\", }", "{\"name\" x}", "[", "]}",
			'{"dependencies": {"a": {"path": }}}',
			"{\"name\": " .. rng.bytes(20) .. "}",
		})
	else
		-- JSON5-ish (unquoted keys, comments, trailing commas).
		return '{\n  // comment\n  name: "pkg",\n  version: "0.1.0",\n  dependencies: {},\n}'
	end
end

---@param rng fuzz.Rng
---@param dir string
local function generateBuildScript(rng, dir)
	if rng.chance(0.6) then return end -- no build.lua: symlink path

	local rel = rng.token(12)
	local content = rng.pick({
		[[local build = require("lde-build")
build:write("out.txt", "hi")
]],
		[[local build = require("lde-build")
build:write("]] .. rel .. [[", "]] .. rng.token(20) .. [[")
]],
		[[local build = require("lde-build")
build:sh("echo built")
]],
		'error("build boom")',
		"os.exit(1)",
		"not lua at all",
		"local build = require(\"lde-build\")\nbuild:read(\"missing.txt\")",
		"function(",
	})
	fs.write(path.join(dir, "build.lua"), content)
end

---@param rng fuzz.Rng
---@param dir string
local function generateSrc(rng, dir)
	local srcDir = path.join(dir, "src")
	if rng.chance(0.15) then
		-- src/ missing entirely, or src is a plain file.
		if rng.chance(0.5) then
			fs.write(path.join(dir, "src"), "i am a file not a dir")
		end
		return
	end
	fs.mkdir(srcDir)

	local entry = rng.pick({
		'return "pkg"',
		'error("src boom")',
		'print("hi")',
		'require("missing-module")',
		"local x = {}; return x.y",
		"os.exit(3)",
		"for i=1,1e7 do end", -- heavy but finite
		"return function() end",
		"-- just a comment",
		"", "1 +",
		"return {}",
		"return require(\"dep-a\")",
		"return { name = 42 }",
		function() return rng.token(60) end,
	})
	if type(entry) == "function" then entry = entry() end
	fs.write(path.join(srcDir, "init.lua"), entry)

	-- Occasional extra files: nested dirs, weird extensions, a test file.
	for _ = 1, rng.int(3) do
		local rel
		if rng.chance(0.5) then
			rel = path.join(rng.token(8), rng.token(8) .. ".lua")
			fs.mkdirAll(path.join(srcDir, path.dirname(rel)))
		else
			-- No .tl/.moon: compiling those triggers a compiler download (network),
			-- which would break the fuzzer's hermetic guarantees.
			rel = rng.token(8) .. rng.pick({ ".lua", ".txt", ".md", ".json", ".so", ".dll" })
		end
		fs.write(path.join(srcDir, rel), rng.bytes(rng.int(40) + 1))
	end

	if rng.chance(0.3) then
		local testsDir = path.join(dir, "tests")
		fs.mkdir(testsDir)
		fs.write(path.join(testsDir, "x.test.lua"), rng.pick({
			'local test = require("lde-test")\ntest.it("a", function() test.equal(1, 2) end)',
			'local test = require("lde-test")\ntest.it("a", function() test.equal(1, 1) end)',
			"not lua",
		}))
	end
end

---@param rng fuzz.Rng
---@param dir string
local function generateLockfile(rng, dir)
	if rng.chance(0.5) then return end -- no lockfile
	local content = rng.pick({
		"{}",
		'{"version": "1", "dependencies": {}}',
		'{"version": "1", "dependencies": {"a": {"path": "../deps/dep-a"}}}',
		'{"version": "999", "dependencies": {}}',
		"garbage",
		"{\"version\": \"1\", \"dependencies\":",
		"[[[]]]]]]",
		function() return rng.bytes(rng.int(30) + 1) end,
	})
	if type(content) == "function" then content = content() end
	fs.write(path.join(dir, "lde.lock"), content)
end

-- Commands to run against each generated project. `add`/`remove` mutate the
-- manifest, which makes later cases on the same project more interesting.
local COMMANDS = {
	"run", "run", "run", "run",
	"tree", "tree",
	"test", "test",
	"sync", "install",
	"update", "outdated",
	"add", "remove",
	"uninstall",
	"bundle", "compile",
}

---@param rng fuzz.Rng
---@param ctx { base: string, deps: string[], gitRepo: string }
---@return string[] args
local function randomCommandArgs(rng, ctx)
	local cmd = rng.pick(COMMANDS)
	local args = { cmd }
	if cmd == "add" then
		table.insert(args, randomName(rng))
		if rng.chance(0.5) then
			table.insert(args, "--path")
			table.insert(args, rng.pick({ "../deps/dep-a", "../deps/dep-b", rng.token(10) }))
		else
			table.insert(args, "--git")
			table.insert(args, rng.pick({ ctx.gitRepo, "https://nonexistent.invalid/x.git" }))
		end
	elseif cmd == "remove" then
		table.insert(args, rng.pick({ "dep-a", "dep-b", "nope", randomName(rng) }))
	elseif cmd == "uninstall" then
		table.insert(args, randomName(rng))
	elseif cmd == "compile" or cmd == "bundle" then
		if rng.chance(0.5) then table.insert(args, "--outfile") end
	end
	return args
end

---@param bin string
---@param rng fuzz.Rng
---@param count integer
---@param ctx { base: string, deps: string[], gitRepo: string }
---@param record fun(case: table, cwd: string, res: fuzz.RunResult, outcome: string, ms: number)
local function run(bin, rng, count, ctx, record)
	for n = 1, count do
		local caseDir = path.join(ctx.base, "pkg-" .. n)
		fs.rmdir(caseDir)
		fs.mkdirAll(caseDir)

		fs.write(path.join(caseDir, "lde.json"), generateManifest(rng, ctx))
		generateBuildScript(rng, caseDir)
		generateSrc(rng, caseDir)
		generateLockfile(rng, caseDir)

		local args = randomCommandArgs(rng, ctx)
		local timeoutMs = (args[1] == "compile" or args[1] == "bundle") and 60000 or 15000
		local start = ansi.now()
		local res = runner.run(bin, args, { cwd = caseDir, timeoutMs = timeoutMs })
		local ms = (ansi.now() - start) * 1000
		local outcome = res.timedOut and "timeout" or runner.classify("cmd", res.exit, res.out)

		local case = { kind = "cmd", args = args, dir = caseDir, timeoutMs = timeoutMs, note = "package" }
		record(case, caseDir, res, outcome, ms)

		-- Keep failed cases for inspection; drop the rest to bound disk use.
		if outcome ~= "crash" and outcome ~= "raw_error" and outcome ~= "timeout" then
			fs.rmdir(caseDir)
		end
	end
end

return { run = run }
