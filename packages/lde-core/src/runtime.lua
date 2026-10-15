const lua  = require("lua-sys")
local env  = require("env")
const fs   = require("fs")
const path = require("path")
const ansi = require("ansi")
const lde  = require("lde-core")
const teal = require("lde-core.teal")
const moonscript = require("lde-core.moonscript")

local PROFILER_MS_PER_SAMPLE = 1

---@param counts   table<string, number>  stack → sample count
---@param vmstates table<string, number>  vmstate char → sample count
---@param total    number
---@param cwd      string?
local function printProfileReport(counts, vmstates, total, cwd)
	---@param s string
	local function wln(s) io.write(s .. "\n") end

	if total == 0 then
		wln(ansi.format("  {yellow}Profile: no samples collected"))
		return
	end

	local totalMs = total * PROFILER_MS_PER_SAMPLE
	---@param ms number
	local function fmtTime(ms)
		if ms < 1000 then return string.format("~%dms", ms) end
		return string.format("~%.1fs", ms / 1000)
	end

	local BAR_WIDTH = 20
	const vmColors = { N = "green", I = "yellow", C = "cyan", G = "red", J = "magenta" }
	const vmLabels = { N = "JIT compiled", I = "Interpreted", C = "C code", G = "GC", J = "JIT compiler" }
	const vmOrder  = { "N", "I", "C", "G", "J" }

	---@param n number
	---@param color string
	local function bar(n, color)
		const filled = math.max(0, math.min(BAR_WIDTH, math.floor(n / total * BAR_WIDTH + 0.5)))
		const s = filled > 0 ? ansi.colorize(color, string.rep("█", filled)) : ""
		const empty = BAR_WIDTH - filled
		return empty > 0 ? s .. ansi.colorize("gray", string.rep("░", empty)) : s
	end

	---@param loc string
	local function relativize(loc)
		if cwd and loc:sub(1, #cwd + 1) == cwd .. "/" then
			loc = loc:sub(#cwd + 2)
		end
		return (loc:gsub("^target/[^/]+/", ""))
	end

	const sep = ansi.colorize("gray", string.rep("─", 54))

	io.write("\n")
	wln(ansi.format("  {bold}Profile{reset} · {cyan}%s{reset} · {gray}%d samples @ %dms",
		fmtTime(totalMs), total, PROFILER_MS_PER_SAMPLE))
	wln("  " .. sep)
	io.write("\n")

	wln(ansi.format("  {bold}VM State"))
	for _, state in ipairs(vmOrder) do
		local n = vmstates[state] or 0
		if n > 0 then
			local color = vmColors[state]
			wln("  "
				.. ansi.colorize(color, string.format("%-12s", vmLabels[state]))
				.. "  " .. bar(n, color)
				.. "  " .. ansi.colorize("gray", string.format("%5.1f%%", n / total * 100)))
		end
	end

	io.write("\n")
	wln(ansi.format("  {bold}Hotspots"))
	wln("  " .. sep)

	local sorted = {}
	for loc, count in pairs(counts) do sorted[#sorted + 1] = { loc = loc, count = count } end
	table.sort(sorted, |a, b| -> a.count > b.count)

	for i = 1, math.min(#sorted, 20) do
		local e     = sorted[i]
		const pct   = e.count / total * 100
		const color = i == 1 ? "red" : i <= 3 ? "yellow" : "white"
		wln("  "
			.. ansi.colorize(color, string.format("%5.1f%%", pct))
			.. "  " .. ansi.colorize("gray", string.format("%-7s", fmtTime(e.count * PROFILER_MS_PER_SAMPLE)))
			.. "  " .. relativize(e.loc))
	end

	io.write("\n")
end

---@param state lua.State
---@return fun(): table, table, table, number
local function startProfiler(state)
	local counts   = {}
	local vmstates = {}
	local stacks   = {}
	local total    = 0

	-- lde internals / Lua builtins that top every stack and make poor hotspot keys.
	const skipFrames = {
		["require"]    = true,
		["pcall"]      = true,
		["xpcall"]     = true,
		["[string]"]   = true,
		["chunk"]      = true,
	}

	-- Strip the name:line suffix luajit appends in "f;" mode (e.g. "foo:42" → "foo").
	---@param f string
	local function frameName(f)
		return (f:gsub(":%d+$", ""))
	end

	lua.profiler.start(state, "fi" .. PROFILER_MS_PER_SAMPLE, function(stack, samples, vmstate)
		total += samples
		vmstates[vmstate] = (vmstates[vmstate] or 0) + samples
		if vmstate == "G" or not stack or stack == "" then return end

		local cleanParts = {}
		for frame in stack:gmatch("([^;]+)") do
			const name = frameName(frame)
			if name ~= "" and name ~= "?" then
				cleanParts[#cleanParts + 1] = name
			end
		end
		const cleanStack = table.concat(cleanParts, ";")
		if cleanStack ~= "" then
			stacks[cleanStack] = (stacks[cleanStack] or 0) + samples
		end

		local key
		for _, part in ipairs(cleanParts) do
			if not skipFrames[part] then
				key = part
				break
			end
		end
		key = key or cleanParts[1]
		if key then
			counts[key] = (counts[key] or 0) + samples
		end
	end)

	return function()
		lua.profiler.stop(state)
		return counts, vmstates, stacks, total
	end
end

--- Written as JSON so tools/tests can consume it programmatically (the text report and HTML flamegraph are human-facing).
---@param filePath string
---@param counts table<string, number> # function -> sample count
---@param vmstates table<string, number> # vmstate char -> sample count
---@param stacks table<string, number> # folded stack -> sample count
---@param total number
---@return boolean? ok
---@return string? err
local function writeProfileJson(filePath, counts, vmstates, stacks, total)
	local hotspots = {}
	for loc, count in pairs(counts) do
		hotspots[#hotspots + 1] = { loc = loc, count = count }
	end
	table.sort(hotspots, |a, b| -> a.count > b.count)

	const json = require("json")
	const content = json.encode({
		version = 1,
		intervalMs = PROFILER_MS_PER_SAMPLE,
		total = total,
		totalMs = total * PROFILER_MS_PER_SAMPLE,
		vmstates = vmstates,
		hotspots = hotspots,
		stacks = stacks,
	})
	if not content then return nil, "failed to encode profile data" end
	if not fs.write(filePath, content) then
		return nil, "failed to write " .. filePath
	end
	return true
end

---@class lde.ExecuteOptions
---@field env          table<string, string>?
---@field args         string[]?  # positional args; args[0] is arg[0] (chunk name / script path)
---@field globals      table<string, any>?
---@field packagePath  string?
---@field packageCPath string?
---@field preload      table<string, function>?  modules injected into package.loaded before execution
---@field cwd          string?
---@field profile      boolean?
---@field flamegraph   string?
---@field profileJson  string? # path: also write the sampled data as JSON
---@field jit          boolean? # JIT diagnostics: report trace aborts with reasons and locations

--- Single source of truth for the guest environment; callers keep the state open to drive it (eval chunks, a REPL loop, ...). Call cleanup() to restore the host cwd/env and state:close() to free the guest.
---@param opts lde.ExecuteOptions?
---@return lua.State state
---@return lua.Table g      # live proxy of the guest globals
---@return fun()     cleanup # restores cwd and env vars on the host
local function createState(opts)
	opts = opts or {}

	-- Change cwd on the host process (guest inherits the same OS environment)
	local oldCwd
	const here = opts.cwd
	if here then
		oldCwd = env.cwd()
		env.chdir(here --[[@as string]])
	end

	const oldEnvVars = {}
	if opts.env then
		for k, v in pairs(opts.env) do
			oldEnvVars[k] = env.var(k)
			env.set(k, v)
		end
	end

	local function cleanup()
		for k, v in pairs(oldEnvVars) do env.set(k, v) end
		if oldCwd then env.chdir(oldCwd) end
	end

	local state = lua.new()
	local g     = state:globals() --[[@as { package: { path: string?, cpath: string?, loaded: table<string, any> }, arg: any }]]

	const pkg = g.package
	if opts.packagePath  then pkg.path  = opts.packagePath  end
	if opts.packageCPath then pkg.cpath = opts.packageCPath end

	-- Injected into package.loaded (not as loaders) so require() returns them immediately with no cross-boundary callback.
	if opts.preload then
		const loaded = pkg.loaded
		for modname, loader in pairs(opts.preload) do
			if type(loader) == "function" then
				loaded[modname] = loader()
			end
		end
	end

	-- toLua handles all types, including plain host tables.
	if opts.globals then
		for k, v in pairs(opts.globals) do
			if v ~= nil then g[k] = v end
		end
	end

	local args   = opts.args or {}
	const argTbl = state:table()
	argTbl[0]   = args[0] or "?"
	for i, v in ipairs(args) do argTbl[i] = v end
	g.arg = argTbl

	return state, g, cleanup
end

---@param source    string  Lua source code to run
---@param chunkName string  Label shown in error traces
---@param opts      lde.ExecuteOptions?
---@return any ...  error message on failure, return values on success
local function executeSource(source, chunkName, opts)
	opts = opts or {}
	local args = opts.args or {}
	-- Callers that run a file pre-set arg[0] to the plain path so the "@"-prefixed chunk name (which LuaJIT needs for path:line errors) doesn't leak into arg[0].
	if args[0] == nil then
		args = { [0] = chunkName, unpack(args) }
	end

	local state, _, cleanup = createState({
		args = args,
		cwd = opts.cwd,
		env = opts.env,
		packagePath = opts.packagePath,
		packageCPath = opts.packageCPath,
		preload = opts.preload,
		globals = opts.globals,
	})

	-- Installed after the state exists so its jit.attach bootstrap chunk can load into it.
	local jitDiagSession, jitdiagReport
	if opts.jit then
		const jitdiag = require("lde-core.jitdiag")
		jitDiagSession = jitdiag.install(state, { cwd = opts.cwd or env.cwd() })
		if jitDiagSession then
			jitdiagReport = function(session, cwd) jitdiag.report(session, cwd) end
		end
	end

	local stopProfiler
	if opts.profile or opts.flamegraph or opts.profileJson then
		stopProfiler = startProfiler(state)
	end

	local chunk = state:load(source, chunkName)
	local ok, a, b, c, d, e, f = pcall(chunk.eval, chunk, unpack(args))

	if stopProfiler then
		local counts, vmstates, stacks, total = stopProfiler()
		-- Artifacts are always written (the caller requested them), but the report/status lines are suppressed while lde.isQuiet (the test runner sets it so library calls under `lde test` don't spam the suite).
		const isQuiet = lde.isQuiet
		if not isQuiet and opts.profile then
			printProfileReport(counts, vmstates, total, opts.cwd or env.cwd())
		end
		const flamegraph = opts.flamegraph
		if flamegraph then
			const title = chunkName and chunkName:match("[^/\\\\]+$")
			const fgOk, fgErr = lde.flamegraph.write(
				stacks, total, PROFILER_MS_PER_SAMPLE, flamegraph --[[@as string]], title)
			if not isQuiet then
				if fgOk then
					ansi.printf("{cyan}Flamegraph written to %s", opts.flamegraph)
				else
					ansi.printf("{red}Flamegraph error: %s", fgErr or "unknown error")
				end
			end
		end
		const profileJson = opts.profileJson
		if profileJson then
			const jOk, jErr = writeProfileJson(profileJson --[[@as string]], counts, vmstates, stacks, total)
			if not isQuiet then
				if jOk then
					ansi.printf("{cyan}Profile JSON written to %s", opts.profileJson)
				else
					ansi.printf("{red}Profile JSON error: %s", jErr or "unknown error")
				end
			end
		end
	end

	if jitDiagSession and not lde.isQuiet then
		jitdiagReport(jitDiagSession, opts.cwd or env.cwd())
	end

	state:close()
	cleanup()

	return ok, a, b, c, d, e, f
end

--- Shared by executeFile and the --hot/--watch driver so both re-read the entry point identically on every run.
---@param filePath string
---@return string? source
---@return string? err
local function readCompiledFile(filePath)
	local source, err = fs.read(filePath)
	if not source then
		return nil, "Failed to read " .. filePath .. ": " .. (err or "unknown error")
	end
	if filePath:match("%.tl$") and not filePath:match("%.d%.tl$") then
		local code, cerr = teal:compileFile(filePath)
		if not code then
			return nil, "Failed to compile " .. filePath .. ":\n" .. (cerr or "unknown error")
		end
		return code, nil
	elseif filePath:match("%.moon$") then
		local code, cerr = moonscript:compileFile(filePath)
		if not code then
			return nil, "Failed to compile " .. filePath .. ":\n" .. (cerr or "unknown error")
		end
		return code, nil
	end
	return source, nil
end

---@param scriptPath string
---@param opts lde.ExecuteOptions?
local function executeFile(scriptPath, opts)
	opts = opts or {}
	-- Resolve relative paths against opts.cwd first so callers can pass e.g. "./scripts/foo.lua" with a cwd override.
	local resolvedPath = scriptPath
	if opts.cwd and not path.isAbsolute(scriptPath) then
		resolvedPath = path.join(opts.cwd, scriptPath)
	end
	local source, err = readCompiledFile(resolvedPath)
	if not source then return false, err end
	-- The "@" chunk label makes LuaJIT report file-backed errors as path:line:msg; a bare path would render as [string "<path>"] with the truncated source text.
	local args = opts.args or {}
	opts.args = { [0] = resolvedPath, unpack(args) }
	return executeSource(source, "@" .. resolvedPath, opts)
end

---@param code string
---@param opts lde.ExecuteOptions?
local function executeString(code, opts)
	return executeSource(code, "-e", opts)
end

--- Test harnesses use the lde binary as their Lua interpreter and depend on these
--- semantics: a prelude `-e` chunk (e.g. luacov's runner) runs before the script in
--- the same state, with a rebuilt arg table (arg[0] = script).
---@param args string[] # the command line after `--lua`
---@param opts lde.ExecuteOptions?
---@return boolean ok
---@return any err
local function executeLuaCLI(args, opts)
	opts = opts or {}

	const eChunks = {}
	local i = 1
	while args[i] == "-e" do
		i += 1
		if args[i] == nil then
			return false, "no code given for -e"
		end
		eChunks[#eChunks + 1] = args[i]
		i += 1
	end
	---@type string?
	local script = args[i]
	local scriptArgs = {}
	for j = i + 1, #args do scriptArgs[#scriptArgs + 1] = args[j] end
	const interactive = script == "-i"
	if interactive then script = nil end
	if not script and #eChunks == 0 and not interactive then
		return false, "no script or -e chunk given after --lua"
	end

	scriptArgs[0] = script or "-e"
	local state, _, cleanup = createState({
		args = scriptArgs,
		cwd = opts.cwd,
		env = opts.env,
		packagePath = opts.packagePath,
		packageCPath = opts.packageCPath,
	})

	local ok, r = true, nil
	for _, code in ipairs(eChunks) do
		local chunk, err = state:load(code, "-e")
		if not chunk then
			ok, r = false, err
			break
		end
		ok, r = pcall(chunk.eval, chunk)
		if not ok then break end
	end

	if ok and interactive then
		local repl, err = state:load([[
			while true do
				io.write("> ")
				io.flush()
				local line = io.read()
				if not line then break end
				local chunk = line:match("^=(.*)$")
				if chunk then chunk = "return " .. chunk else chunk = line end
				local f, err = loadstring(chunk)
				if f then
					local pok, a = pcall(f)
					if not pok then print(tostring(a))
					elseif a ~= nil then print(tostring(a)) end
				else
					print(tostring(err))
				end
			end
		]], "@repl")
		if not repl then
			ok, r = false, err
		else
			ok, r = pcall(repl.eval, repl)
		end
	elseif ok and script then
		local source, err = fs.read(script --[[@as string]])
		if not source then
			ok, r = false, "Failed to read " .. script .. ": " .. (err or "unknown error")
		else
			local chunk, lerr = state:load(source, "@" .. script)
			if not chunk then
				ok, r = false, lerr
			else
				ok, r = pcall(chunk.eval, chunk, unpack(scriptArgs))
			end
		end
	end

	state:close()
	cleanup()
	return ok, r
end

return {
	createState     = createState,
	executeFile     = executeFile,
	executeString   = executeString,
	executeLuaCLI   = executeLuaCLI,
	readCompiledFile = readCompiledFile,
}
