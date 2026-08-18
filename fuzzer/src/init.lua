-- fuzzer/src/init.lua
--
-- lde fuzzing suite. Usage:
--
--   cd fuzzer
--   lde sync
--   LDE=/path/to/lde lde run -- [--seed N] [--count N] [--cli-only | --packages-only]
--
-- Runs a grammar-based CLI fuzzer and a package-content fuzzer against the
-- binary under test (LDE env, default "lde" from PATH), records every case
-- to .fuzz/results.csv, and exits non-zero if any case produced a crash, a
-- leaked raw traceback, or a hang.

local fs = require("fs")
local path = require("path")
local env = require("env")
local process = require("process")
local ansi = require("ansi")
local json = require("json")

local rngLib = require("fuzzer.rng")
local runner = require("fuzzer.runner")
local cliFuzz = require("fuzzer.cli")
local pkgFuzz = require("fuzzer.packages")

local rawArgs = { ... }

local seed = os.time()
local count = 500
local only = nil ---@type "cli"|"packages"?
local i = 1
while i <= #rawArgs do
	local a = rawArgs[i]
	if a == "--seed" then
		seed = tonumber(rawArgs[i + 1]) or os.time()
		i = i + 1
	elseif a == "--count" then
		count = tonumber(rawArgs[i + 1]) or 500
		i = i + 1
	elseif a == "--cli-only" then
		only = "cli"
	elseif a == "--packages-only" then
		only = "packages"
	elseif a == "--help" then
		print([[lde fuzzer

Usage: LDE=<binary> lde run -- [--seed N] [--count N] [--cli-only | --packages-only]

Fuzzes the lde CLI and package contents, recording every outcome to
.fuzz/results.csv. Exits 1 if any crash / raw traceback / hang is found.

  --seed N          PRNG seed (default: time; reuse to reproduce a run)
  --count N         cases per fuzzer (default: 500)
  --cli-only        skip the package-content fuzzer
  --packages-only   skip the CLI fuzzer]])
		return
	else
		ansi.printf("{red}Unknown fuzzer arg: %s", tostring(a))
		os.exit(1)
	end
	i = i + 1
end

local LDE = os.getenv("LDE") or "lde"
local base = os.getenv("LDE_FUZZ_DIR") or path.join(os.getenv("PWD") or ".", ".fuzz")

ansi.printf("{bold}lde fuzzer{reset} — seed {yellow}%d{reset}, {yellow}%d{reset} cases/fuzzer, binary: {cyan}%s{reset}", seed, count, LDE)
ansi.printf("scratch: {gray}%s{reset}", base)

-- Isolate everything: a scratch HOME keeps ~/.lde caches and git config out
-- of the real user environment; NO_COLOR makes output classification exact.
local home = path.join(base, "home")
fs.mkdirAll(home)
env.set("HOME", home)
env.set("NO_COLOR", "1")

---@param deps table<string, string>
---@return string
local function manifestJson(deps)
	return json.encode({ name = "fuzz-base", version = "0.1.0", dependencies = deps })
end

-- Scratch contexts shared by both fuzzers.
local ctx = {
	base = base,
	cliEmpty = path.join(base, "cli-empty"),
	cliProject = path.join(base, "cli-project"),
	deps = { path.join(base, "deps", "dep-a"), path.join(base, "deps", "dep-b") },
	gitRepo = path.join(base, "deps", "git-repo"),
}

fs.rmdir(ctx.cliEmpty)
fs.mkdirAll(ctx.cliEmpty)

-- cli-project: a real project with two path deps, so installs are fast and
-- offline-safe for the CLI fuzz cases.
fs.rmdir(ctx.cliProject)
fs.mkdirAll(path.join(ctx.cliProject, "src"))
fs.write(path.join(ctx.cliProject, "src", "init.lua"), 'return "cli-project"')
fs.write(path.join(ctx.cliProject, "lde.json"), manifestJson({ ["dep-a"] = "../deps/dep-a", ["dep-b"] = "../deps/dep-b" }))

for _, depDir in ipairs(ctx.deps) do
	fs.rmdir(depDir)
	fs.mkdirAll(path.join(depDir, "src"))
	fs.write(path.join(depDir, "src", "init.lua"), 'return "' .. path.basename(depDir) .. '"')
	fs.write(path.join(depDir, "lde.json"), manifestJson({}))
end

-- Local git repo for git-dep fuzz cases (offline clone).
fs.rmdir(ctx.gitRepo)
fs.mkdirAll(path.join(ctx.gitRepo, "src"))
fs.write(path.join(ctx.gitRepo, "src", "init.lua"), 'return "git-dep"')
fs.write(path.join(ctx.gitRepo, "lde.json"), manifestJson({}))
local gitCode = process.exec("git", { "init", "-q" }, { cwd = ctx.gitRepo })
if gitCode ~= 0 then
	ansi.printf("{red}git init failed (code %s)", tostring(gitCode))
	os.exit(1)
end
process.exec("git", { "add", "-A" }, { cwd = ctx.gitRepo })
gitCode = process.exec("git", { "-c", "user.name=fuzz", "-c", "user.email=fuzz@fuzz", "commit", "-q", "-m", "init" }, { cwd = ctx.gitRepo })
if gitCode ~= 0 then
	ansi.printf("{red}git commit failed (code %s)", tostring(gitCode))
	os.exit(1)
end

-- Loose scripts exercised through `lde --lua`.
local scriptsDir = path.join(base, "scripts")
fs.rmdir(scriptsDir)
fs.mkdirAll(scriptsDir)
fs.write(path.join(scriptsDir, "ok.lua"), 'print("ok")')
fs.write(path.join(scriptsDir, "boom.lua"), 'error("boom")')
fs.write(path.join(scriptsDir, "syntax.lua"), "1 +")
fs.write(path.join(scriptsDir, "loop.lua"), "while true do end")

-- Result recording: CSV rows plus a findings log with full outputs.
local rows = {}
local findings = {} ---@type table[]
local totalMs = 0

---@param case { kind: string, note: string, args: string[] }
---@param cwd string
---@param res fuzz.RunResult
---@param outcome string
---@param ms number
local function record(case, cwd, res, outcome, ms)
	totalMs = totalMs + ms
	local args = table.concat(case.args, " ")
	local exit = res.timedOut and "TIMEOUT" or (res.exit ~= nil and tostring(res.exit) or "SPAWN-FAIL")
	table.insert(rows, { seed, #rows + 1, case.kind, case.note, cwd, exit, outcome, ms, args })

	if #rows % 100 == 0 then
		ansi.printf("{gray}  case %d: %s{reset}", #rows, args)
	end

	-- eval/lua cases run user code, so a hang there is the user's loop, not an
	-- lde bug — only command cases treat timeouts as findings.
	local isFinding = outcome == "crash" or outcome == "raw_error"
		or (outcome == "timeout" and case.kind == "cmd")
	if isFinding then
		table.insert(findings, {
			outcome = outcome,
			args = args,
			cwd = cwd,
			exit = res.exit,
			ms = ms,
			out = res.out,
			spawnError = res.spawnError,
		})
	end
end

local rng = rngLib.new(seed)

local function runSection(name, fn)
	if only and only ~= name then return end
	ansi.printf("\n{bold}== %s =={reset}", name)
	local start = ansi.now()
	fn()
	ansi.printf("{gray}%s done in %.1fs{reset}", name, ansi.now() - start)
end

runSection("cli", function()
	cliFuzz.run(LDE, rng, count, ctx, record)
end)

runSection("packages", function()
	pkgFuzz.run(LDE, rng, count, ctx, record)
end)

-- Sanity: the binary must actually be spawnable.
if #rows == 0 then
	ansi.printf("{red}No cases ran — is the binary at %s?", LDE)
	os.exit(1)
end

-- Write results.csv.
local csvPath = path.join(base, "results.csv")
local csv = { "seed,index,kind,note,cwd,exit,outcome,ms,args" }
for _, row in ipairs(rows) do
	csv[#csv + 1] = table.concat({
		row[1], row[2], row[3], runner.csvField(row[4]), runner.csvField(row[5]),
		row[6], row[7], string.format("%.0f", row[8]), runner.csvField(row[9]),
	}, ",")
end
fs.mkdirAll(base)
fs.write(csvPath, table.concat(csv, "\n") .. "\n")

-- Findings log with full outputs for repro.
local findingsPath = path.join(base, "findings.log")
local flines = { "seed=" .. seed, "binary=" .. LDE }
for _, f in ipairs(findings) do
	flines[#flines + 1] = string.format(
		"\n=== %s | exit=%s | %.0fms | cwd=%s ===", f.outcome, tostring(f.exit), f.ms, f.cwd)
	flines[#flines + 1] = "$ " .. LDE .. " " .. f.args
	if f.spawnError then
		flines[#flines + 1] = "spawn error: " .. f.spawnError
	end
	flines[#flines + 1] = f.out
end
fs.write(findingsPath, table.concat(flines, "\n") .. "\n")

-- Summary.
local counts = {} ---@type table<string, integer>
for _, row in ipairs(rows) do
	counts[row[7]] = (counts[row[7]] or 0) + 1
end

ansi.printf("\n{bold}== results =={reset}  ({gray}%s{reset})", csvPath)
for _, outcome in ipairs({ "ok", "clean_error", "crash", "raw_error", "timeout" }) do
	local color = (outcome == "ok" or outcome == "clean_error") and "green" or "red"
	ansi.printf("  {" .. color .. "}%s{reset}: %d", outcome, counts[outcome] or 0)
end
ansi.printf("  total: %d cases, %.1fs", #rows, totalMs / 1000)

if #findings > 0 then
	ansi.printf("\n{red}{bold}%d finding(s) — see %s{reset}", #findings, findingsPath)
	for _, f in ipairs(findings) do
		ansi.printf("  {red}%s{reset}: $ %s {gray}(exit %s, %.0fms){reset}", f.outcome, f.args, tostring(f.exit), f.ms)
	end
	os.exit(1)
end

ansi.printf("{green}No crashes, raw tracebacks, or hangs found.{reset}")
