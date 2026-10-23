-- fuzzer/src/cli.lua
--
-- Grammar-based CLI fuzzer: generates invocations from the real command
-- surface (commands, flags, hidden backends) mixed with garbage values, and
-- runs each against the binary under test.

local runner = require("fuzzer.runner")

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

local function randomValue(rng)
	return rng.value({
		"", "a", "s", "x", "-", "--", "--flag", "--help",
		"hello world", "日本語", "\27[31m", "{red}", "{bold}x{reset}",
		"..", ".", "/", "/tmp/x", "C:\\Windows", "~", "~/x",
		"http://example.com", "git@github.com:user/repo.git",
		"name", "name@1.0.0", "ns/name", "rocks:luasocket",
		"gh:user/repo", "github:user/repo", "gitlab:user/repo", "codeberg:user/repo",
		"gh:pkg@user/repo",
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

---@param rng fuzz.Rng
---@param ctx { depA: string, depB: string, cliProject: string }
local function randomPath(rng, ctx)
	return rng.value({
		".", "..", "/tmp", "/nonexistent", "src", "target", "",
		ctx.depA, ctx.depB, ctx.cliProject,
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
	return rng.value({
		function() return rng.pick(LUA_SNIPPETS) end,
		function() return rng.pick(LUA_SNIPPETS) end,
		function() return rng.token(rng.int(40) + 1) end,
	})
end

---@param rng fuzz.Rng
---@param ctx { depA: string, depB: string, cliProject: string }
---@return { kind: "cmd" | "eval" | "lua", args: string[], timeoutMs: integer, note: string }
local function generate(rng, ctx)
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
			table.insert(args, randomPath(rng, ctx))
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
		table.insert(args, ctx.depA)
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
		for _ = 1, rng.int(3) do table.insert(args, randomPath(rng, ctx)) end
	end

	-- Long-running commands get a generous deadline.
	local timeoutMs = (cmd == "compile" or cmd == "bundle") and 60000 or 10000
	return { kind = "cmd", args = args, timeoutMs = timeoutMs, note = cmd }
end

---@param bin string # binary under test
---@param rng fuzz.Rng
---@param count integer
---@param ctx { base: string, cliEmpty: string, cliProject: string, depA: string, depB: string }
---@param record fun(case: table, cwd: string, res: fuzz.RunResult, outcome: string, ms: number)
local function run(bin, rng, count, ctx, record)
	for n = 1, count do
		local case = generate(rng, ctx)
		-- --lua cases reference scripts/* relative to their cwd, which lives in
		-- the scratch base dir; everything else runs in one of the projects.
		local project = rng.chance(0.5) and ctx.cliEmpty or ctx.cliProject
		local cwd = case.kind == "lua" and ctx.base or project
		local res, outcome, ms = runner.runCase(bin, case, cwd)
		record(case, cwd, res, outcome, ms)
	end
end

return { run = run }
