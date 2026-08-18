-- fuzzer/src/cli.lua
--
-- Grammar-based CLI fuzzer: generates invocations from the real command
-- surface (commands, flags, hidden backends) mixed with garbage values, and
-- runs each against the binary under test.

local rngLib = require("fuzzer.rng")
local runner = require("fuzzer.runner")
local ansi = require("ansi")

-- Commands that hit the network (publish, upgrade, registry/luarocks
-- resolution, bare `x`) are excluded so the suite stays hermetic and fast.
local COMMANDS = {
	"help", "help", "help",
	"init", "new", "new",
	"add", "remove",
	"run", "run", "run", "run",
	"install", "i", "sync",
	"bundle", "compile",
	"test", "test",
	"tree", "update", "outdated",
	"uninstall",
	"completion", "completion",
	"repl",
	"__complete", "__build-pkg",
	"frobnicate", "s", "",
}

-- Per-command flags. `--hot`/`--watch` are excluded: they block forever by
-- design. Flags in TAKES_VALUE consume the next token.
local COMMAND_FLAGS = {
	run = { "--profile", "--flamegraph", "--json" },
	test = { "--coverage", "--json" },
	compile = { "--outfile" },
	new = { "--type", "--language", "--name" },
	add = { "--dev", "--git", "--path" },
	install = { "--production" },
	sync = { "--locked" },
	x = { "--git", "--path", "--offline" },
}

local TAKES_VALUE = {
	["--type"] = true, ["--language"] = true, ["--name"] = true,
	["--outfile"] = true, ["--git"] = true, ["--path"] = true,
	["-C"] = true, ["--tree"] = true,
}

--- Materialize a value shape: static strings stay, functions generate fresh
--- garbage so the rng advances per call.
---@param rng fuzz.Rng
---@param shapes any[]
---@return string
local function materialize(rng, shapes)
	local v = rng.pick(shapes)
	if type(v) == "function" then return v() end
	return v
end

local function randomValue(rng)
	return materialize(rng, {
		"", "a", "s", "x", "-", "--", "--flag", "--help",
		"hello world", "日本語", "\27[31m", "{red}", "{bold}x{reset}",
		"..", ".", "/", "/tmp/x", "C:\\Windows", "~", "~/x",
		"http://example.com", "git@github.com:user/repo.git",
		"name", "name@1.0.0", "ns/name", "rocks:luasocket",
		"tests", "target", "src", "src/init.lua", "lde.json", "lde.lock",
		"123", "0", "-1", "1e999", "0x10", "true", "false", "nil",
		"%s", "%d", "%%", "%n", "'\"\\", "{|}[];,:=&|",
		function() return rng.bytes(rng.int(50) + 1) end,
		function() return rng.bytes(rng.int(500) + 1) end,
		function() return rng.token(rng.int(30) + 1) end,
		function() return rng.token(500) end,
		function() return string.rep("x", rng.int(200) + 1) end,
	})
end

local function randomPath(rng)
	return materialize(rng, {
		".", "..", "/tmp", "/nonexistent", "src", "target", "",
		"../deps/dep-a", "../deps/dep-b", "../cli-project",
	})
end

-- `-e` runs user code: syntax errors, runtime errors, weird values are all
-- legitimate (cleanly reported) — the fuzzer's job is to ensure they never
-- escape as lde bugs. One infinite loop is included as a known-hang case.
local LUA_SNIPPETS = {
	"return 1", "print('hi')", "error('boom')", "error({})",
	"require('nonexistent')", "local t = {}; return t.x.y", "return nil",
	"os.exit(0)", "os.exit(3)", "1 +", "function(", "return {}",
	"collectgarbage('collect')", "for i=1,1e5 do end", "tonumber('x')",
	"local f = assert(load('return 1')); return f()", "", " ",
	"return '\\27[31m'", "print('{red}')", "error('a\\nb')", "x = y",
	"local x = 1", "return 1, 2, 3", "return", "os.exit(2)",
	"while true do end",
}

local function randomLuaCode(rng)
	return materialize(rng, {
		function() return rng.pick(LUA_SNIPPETS) end,
		function() return rng.pick(LUA_SNIPPETS) end,
		function() return rng.token(rng.int(40) + 1) end,
	})
end

---@param rng fuzz.Rng
---@return { kind: "cmd" | "eval" | "lua", args: string[], timeoutMs: integer, note: string }
local function generate(rng)
	local roll = rng.int(100)
	if roll < 12 then
		return { kind = "eval", args = { "-e", randomLuaCode(rng) }, timeoutMs = 8000, note = "eval" }
	elseif roll < 18 then
		-- --lua: the binary as a plain Lua interpreter, then -e / scripts.
		local args = { "--lua" }
		local n = rng.int(3)
		for _ = 1, n do
			if rng.chance(0.5) then
				table.insert(args, "-e")
				table.insert(args, randomLuaCode(rng))
			else
				table.insert(args, rng.pick({
					"scripts/ok.lua", "scripts/boom.lua", "scripts/syntax.lua",
					"scripts/loop.lua", "nonexistent.lua", "-i",
				}))
			end
		end
		return { kind = "lua", args = args, timeoutMs = 8000, note = "lua" }
	end

	local args = {}

	-- Global flag prefix sometimes (-C/--tree take a value).
	if rng.chance(0.3) then
		local g = rng.pick({ "-C", "--tree", "--version", "-v", "--help", "--update-path", "--setup" })
		if TAKES_VALUE[g] then
			table.insert(args, g)
			table.insert(args, randomPath(rng))
		else
			table.insert(args, g)
		end
	end

	local cmd = rng.pick(COMMANDS)
	table.insert(args, cmd)

	-- `add` without a source flag resolves from the registry (network); always
	-- point it at the local deps instead.
	if cmd == "add" then
		table.insert(args, "--path")
		table.insert(args, "../deps/dep-a")
	end

	local flags = COMMAND_FLAGS[cmd]
	if flags and rng.chance(0.6) then
		local flag = rng.pick(flags)
		table.insert(args, flag)
		if TAKES_VALUE[flag] then
			table.insert(args, randomValue(rng))
		end
	end

	for _ = 1, rng.int(3) do
		if rng.chance(0.25) then table.insert(args, "--") end
		table.insert(args, randomValue(rng))
	end

	-- Hidden backends need bare args only.
	if cmd == "__complete" or cmd == "__build-pkg" then
		args = { cmd }
		for _ = 1, rng.int(3) do table.insert(args, randomPath(rng)) end
	end

	-- Long-running commands get a generous deadline.
	local timeoutMs = (cmd == "compile" or cmd == "bundle") and 60000 or 10000
	return { kind = "cmd", args = args, timeoutMs = timeoutMs, note = cmd }
end

---@param bin string # binary under test
---@param rng fuzz.Rng
---@param count integer
---@param contexts { cliEmpty: string, cliProject: string }
---@param record fun(case: table, cwd: string, res: fuzz.RunResult, outcome: string, ms: number)
local function run(bin, rng, count, contexts, record)
	for n = 1, count do
		local case = generate(rng)
		local cwd = rng.chance(0.5) and contexts.cliEmpty or contexts.cliProject
		local start = ansi.now()
		local res = runner.run(bin, case.args, { cwd = cwd, timeoutMs = case.timeoutMs })
		local ms = (ansi.now() - start) * 1000
		local outcome = res.timedOut and "timeout" or runner.classify(case.kind, res.exit, res.out)
		record(case, cwd, res, outcome, ms)
	end
end

return { run = run }
