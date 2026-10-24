-- crater/src/init.lua
--
-- Crater: LuaRocks compatibility shotgun for lde. Installs the most-downloaded
-- LuaRocks packages (the corpus and skip/exclude policy live in
-- src/packages.lua) and verifies every module loads under lde's runtime.
--
-- For every package the harness:
--   1. creates a scratch project with `{ "luarocks": "<name>" }` (+ extra deps
--      where the published rockspec forgets a dependency, e.g. busted-hjtest),
--   2. runs `lde install` twice (cold + warm) and times both,
--   3. discovers every Lua/native module lde materialized into target/,
--   4. runs `lde run main.lua`, which `require()`s each discovered module
--      (plus a tiny functional check for a handful of well-known APIs),
--   5. records per-module results and timings into .shotgun/results.csv.
-- Project and smoke-script generation live in src/smoke.lua.
--
-- Every result carries one normalized `status`:
--   ok       install and module run both clean
--   partial  modules failed or their output is missing
--   failed   install or run failed (or the run timed out)
--   skipped  install is expected to fail on this box (see EXPECTED_FAIL)
--   engine   bound to another runtime; never installed (see ENGINE_REASON)
-- The summary counts and the CSV status column are derived from that field.
--
-- Some packages only load when a host runtime global exists (e.g. neovim's
-- `vim` for vusted); a documented deep-stub shim is preloaded for those so
-- install + module-load compatibility can still be verified.
--
-- Usage:
--   cd crater
--   lde sync
--   lde run
--
-- Env:
--   LDE             lde binary to test (default: "lde" from PATH)
--   LDE_SHOTGUN_DIR scratch directory (default: <cwd>/.shotgun)
--   LDE_ONLY        comma-separated package filter (e.g. LDE_ONLY=busted,luasec)

local fs = require("fs")
local path = require("path")
local process = require("process")
local ansi = require("ansi")
local json = require("json")
local packages = require("crater.packages")
local smoke = require("crater.smoke")

local PACKAGES = packages.PACKAGES
local EXPECTED_FAIL = packages.EXPECTED_FAIL
local ENGINE_REASON = packages.ENGINE_REASON

local LDE = os.getenv("LDE") or "lde"
local SCRATCH = os.getenv("LDE_SHOTGUN_DIR") or path.join(os.getenv("PWD") or ".", ".shotgun")
-- Optional filter: only run the given package(s) (comma-separated), e.g. LDE_ONLY=busted,luacheck
local ONLY = {}
for name in (os.getenv("LDE_ONLY") or ""):gmatch("[^,]+") do ONLY[name:match("^%s*(.-)%s*$")] = true end

local INSTALL_TIMEOUT = 600 -- seconds; guarded by GNU timeout(1) when available
local RUN_TIMEOUT = 120

local USE_TIMEOUT = process.exec("timeout", { "--version" }, { stdout = "null", stderr = "null" }) == 0

--- Run a command, bounded by timeoutSec when timeout(1) is available.
--- Returns code, stdout, stderr (code = nil on timeout).
---@param bin string
---@param args string[]
---@param opts { cwd?: string, stdout?: "pipe"|"null", stderr?: "pipe"|"null" }?
---@param timeoutSec number
local function timedExec(bin, args, opts, timeoutSec)
	opts = opts or {}
	local code, stdout, stderr
	if USE_TIMEOUT then
		local argv = { tostring(timeoutSec), bin }
		for _, a in ipairs(args) do argv[#argv + 1] = a end
		code, stdout, stderr = process.exec("timeout", argv, opts)
		if code == 124 then return nil, nil, "timed out after " .. timeoutSec .. "s" end
	else
		code, stdout, stderr = process.exec(bin, args, opts)
	end
	return code, stdout, stderr
end

--- Version pinned in the lockfile entry for this package (from the .src.rock URL).
---@param lockContent string
---@param name string
---@return string?
local function lockVersion(lockContent, name)
	local ok, lock = pcall(json.decode, lockContent)
	if not ok or type(lock) ~= "table" then return nil end
	local dep = type(lock.dependencies) == "table" and lock.dependencies[name] or nil
	local archive = type(dep) == "table" and dep.archive or nil
	if type(archive) ~= "string" then return nil end
	return archive:match("%-([%d%.]+%-%d+)%.src%.rock$")
end

---@param code number?
local function fmtCode(code)
	if code == nil then return "?" end
	return tostring(code)
end

local ldeVersion
do
	local code, stdout = process.exec(LDE, { "--version" }, { stdout = "pipe", stderr = "null" })
	if code ~= 0 then
		ansi.printf("{red}lde binary not found on PATH (set LDE to override){reset}")
		os.exit(1)
	end
	ldeVersion = stdout and stdout:gsub("%s+$", "") or "?"
end

if not fs.isdir(SCRATCH) then fs.mkdirAll(SCRATCH) end

ansi.printf("{bold}LuaRocks shotgun test{reset}  lde=%s  scratch=%s  timeout(1)=%s",
	ldeVersion, SCRATCH, USE_TIMEOUT and "yes" or "no")

local results = {}
for _, pkg in ipairs(PACKAGES) do
	if next(ONLY) and not ONLY[pkg.name] then goto skip end
	local name = pkg.name
	local dir = path.join(SCRATCH, name)
	local targetDir = path.join(dir, "target")

	ansi.printf("\n[{bold}%s{reset}] {bold}%s{reset}  (%s downloads%s)",
		pkg.rank, name, tostring(pkg.downloads),
		(pkg.shims and #pkg.shims > 0) and ("; shim: " .. table.concat(pkg.shims, ",")) or "")

	if pkg.engine then
		local why = ENGINE_REASON[pkg.engine] or ("bound to " .. pkg.engine)
		ansi.printf("  {gray}skipped: %s{reset}", why)
		results[#results + 1] = { pkg = name, status = "engine", detail = why, rank = pkg.rank }
		goto continue
	end

	smoke.makeProject(dir, name, pkg.extra)

	-- Cold install (fresh project; archives may be warm in ~/.lde)
	local t0 = ansi.now()
	local code, _, err = timedExec(LDE, { "install" }, { cwd = dir, stdout = "pipe", stderr = "pipe" }, INSTALL_TIMEOUT)
	local cold = ansi.now() - t0
	if code ~= 0 then
		local skipReason = EXPECTED_FAIL[name]
		if skipReason then
			ansi.printf("  {yellow}install skipped (%.1fs):{reset} %s", cold, skipReason)
			results[#results + 1] = { pkg = name, status = "skipped", detail = skipReason, rank = pkg.rank, cold = cold }
			goto continue
		end
		local detail = "install failed: " .. (err or "")
		ansi.printf("  {red}install FAILED (%.1fs, exit %s):{reset} %s", cold, fmtCode(code),
			(err or "unknown error"):gsub("%s+$", ""))
		results[#results + 1] = { pkg = name, status = "failed", detail = detail, rank = pkg.rank }
		goto continue
	end

	-- Warm install (cached fast path); its result is discarded: the cold
	-- install already succeeded, and the warm run only measures the cache.
	t0 = ansi.now()
	timedExec(LDE, { "install" }, { cwd = dir, stdout = "null", stderr = "null" }, INSTALL_TIMEOUT)
	local warm = ansi.now() - t0

	local lockContent = fs.read(path.join(dir, "lde.lock")) or ""
	local version = lockVersion(lockContent, name)

	-- The alias dir (target/<name>) may *contain* the module itself (e.g.
	-- busted's module materializes as target/busted/init.lua), so only the
	-- project's own output dir and make-install junk dirs are excluded.
	local exclude = { [name .. "-smoke"] = true, bin = true, lib = true, include = true, share = true, etc = true }
	for _, s in ipairs(pkg.skip or {}) do exclude[s] = true end
	local mods = fs.isdir(targetDir) and smoke.discoverModules(targetDir, exclude) or {}

	if #mods == 0 then
		ansi.printf("  {yellow}install OK (%.2fs / warm %.3fs) but no modules materialized in target/{reset}", cold, warm)
		results[#results + 1] = { pkg = name, status = "ok", rank = pkg.rank, version = version, modules = 0, okModules = 0, cold = cold, warm = warm, run = 0 }
		goto continue
	end

	local mainLua, excluded = smoke.makeMainLua(mods, pkg.shims)
	fs.write(path.join(dir, "main.lua"), mainLua)

	t0 = ansi.now()
	local rcode, rout = timedExec(LDE, { "run", "main.lua" }, { cwd = dir, stdout = "pipe", stderr = "pipe" }, RUN_TIMEOUT)
	local run = ansi.now() - t0

	local okCount, funcOk = 0, 0
	local errors = {}
	for line in (rout or ""):gmatch("[^\r\n]+") do
		local kind, mod, extra = line:match("^(%u+)\t([^\t]+)\t?(.*)$")
		if kind == "OK" then
			okCount = okCount + 1
		elseif kind == "FUNC" then
			funcOk = funcOk + 1
		elseif kind == "FUNCERR" or kind == "ERR" then
			errors[#errors + 1] = mod .. ": " .. extra
		end
	end

	local tested = #mods - excluded
	local status, detail
	if rcode == nil then
		status, detail = "failed", "run timed out"
	elseif #errors > 0 then
		status, detail = "partial", "module failures"
	elseif rcode ~= 0 then
		status, detail = "failed", "run exited " .. rcode
	elseif okCount + funcOk < tested then
		status, detail = "partial", "missing module output"
	else
		status, detail = "ok", nil
	end
	ansi.printf("  install {green}%.2fs{reset} / warm {gray}%.3fs{reset}  run {cyan}%.3fs{reset}  modules %d/%d ok%s",
		cold, warm, run, okCount + funcOk, tested,
		version and ("  (" .. name .. " " .. version .. ")") or "")
	if excluded > 0 then
		ansi.printf("    {gray}(excluded %d non-library module(s)){reset}", excluded)
	end
	if #errors > 0 then
		for i = 1, math.min(#errors, 5) do
			ansi.printf("    {red}%s{reset}", errors[i])
		end
		if #errors > 5 then ansi.printf("    ... and %d more", #errors - 5) end
	end

	results[#results + 1] = {
		pkg = name, status = status, detail = detail, rank = pkg.rank, version = version,
		modules = tested, okModules = okCount + funcOk, cold = cold, warm = warm, run = run,
		errors = errors,
	}
	::continue::
	::skip::
end

-- ── Summary ────────────────────────────────────────────────────────────────
local counts = { ok = 0, partial = 0, failed = 0, skipped = 0, engine = 0 }
for _, r in ipairs(results) do counts[r.status] = counts[r.status] + 1 end

ansi.printf("\n{bold}=== Summary ==={reset}")
ansi.printf("{green}%d{reset} fully working, {yellow}%d{reset} partial, {red}%d{reset} failed, {gray}%d{reset} skipped (needs system lib), {gray}%d{reset} other-runtime  (of %d packages)",
	counts.ok, counts.partial, counts.failed, counts.skipped, counts.engine, #results)

local csv = {}
csv[#csv + 1] = "rank,name,version,modules,ok_modules,cold_install_s,warm_install_s,run_s,status,first_error"
local function csvField(s)
	if not s then return "" end
	s = s:gsub("[\r\n]+", " ")
	s = s:gsub('"', '""')
	return '"' .. s .. '"'
end
for _, r in ipairs(results) do
	csv[#csv + 1] = table.concat({
		tostring(r.rank or ""), csvField(r.pkg), csvField(r.version or ""), tostring(r.modules or ""), tostring(r.okModules or ""),
		r.cold and string.format("%.3f", r.cold) or "", r.warm and string.format("%.3f", r.warm) or "",
		r.run and string.format("%.3f", r.run) or "", csvField(r.status),
		csvField(r.errors and r.errors[1] or r.detail or ""),
	}, ",")
end

local csvPath = path.join(SCRATCH, "results.csv")
fs.write(csvPath, table.concat(csv, "\n") .. "\n")
ansi.printf("\nCSV results written to {cyan}%s{reset}", csvPath)

-- Fail the run when any package failed or was only partially verified, so
-- regressions are caught by the exit code (e.g. in CI).
if counts.failed > 0 or counts.partial > 0 then
	ansi.printf("{red}%d package(s) failed or were only partially verified{reset}", counts.failed + counts.partial)
	os.exit(1)
end
