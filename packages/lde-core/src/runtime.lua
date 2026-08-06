local lua  = require("lua-sys")
local env  = require("env")
local fs   = require("fs")
local path = require("path")
local ansi = require("ansi")
local lde  = require("lde-core")

local PROFILER_MS_PER_SAMPLE = 1

--- Prints a fancy profile report: VM state bars + hotspot table.
---@param counts   table<string, number>  stack → sample count
---@param vmstates table<string, number>  vmstate char → sample count
---@param stacks   table<string, number>  folded stack → sample count (for flamegraph)
---@param total    number
---@param cwd      string?
local function printProfileReport(counts, vmstates, total, cwd)
	local function wln(s) io.write(s .. "\n") end

	if total == 0 then
		wln(ansi.format("  {yellow}Profile: no samples collected"))
		return
	end

	local totalMs = total * PROFILER_MS_PER_SAMPLE
	local function fmtTime(ms)
		if ms < 1000 then return string.format("~%dms", ms) end
		return string.format("~%.1fs", ms / 1000)
	end

	local BAR_WIDTH = 20
	local vmColors = { N = "green", I = "yellow", C = "cyan", G = "red", J = "magenta" }
	local vmLabels = { N = "JIT compiled", I = "Interpreted", C = "C code", G = "GC", J = "JIT compiler" }
	local vmOrder  = { "N", "I", "C", "G", "J" }

	local function bar(n, color)
		local filled = math.max(0, math.min(BAR_WIDTH, math.floor(n / total * BAR_WIDTH + 0.5)))
		local s = filled > 0 and ansi.colorize(color, string.rep("█", filled)) or ""
		local empty = BAR_WIDTH - filled
		return empty > 0 and s .. ansi.colorize("gray", string.rep("░", empty)) or s
	end

	local function relativize(loc)
		if cwd and loc:sub(1, #cwd + 1) == cwd .. "/" then
			loc = loc:sub(#cwd + 2)
		end
		return (loc:gsub("^target/[^/]+/", ""))
	end

	local sep = ansi.colorize("gray", string.rep("─", 54))

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
	table.sort(sorted, function(a, b) return a.count > b.count end)

	for i = 1, math.min(#sorted, 20) do
		local e     = sorted[i]
		local pct   = e.count / total * 100
		local color = i == 1 and "red" or i <= 3 and "yellow" or "white"
		wln("  "
			.. ansi.colorize(color, string.format("%5.1f%%", pct))
			.. "  " .. ansi.colorize("gray", string.format("%-7s", fmtTime(e.count * PROFILER_MS_PER_SAMPLE)))
			.. "  " .. relativize(e.loc))
	end

	io.write("\n")
end

--- Start the profiler using a custom callback so we get vmstate per tick.
--- Returns a stop() function that returns counts, vmstates, stacks, total.
---@param state lua.State
---@return fun(): table, table, table, number
local function startProfiler(state)
	local counts   = {}
	local vmstates = {}
	local stacks   = {}
	local total    = 0

	-- Frames to skip when looking for a meaningful hotspot key.
	-- These are lde internals or Lua builtins that appear at the top of every stack.
	local skipFrames = {
		["require"]    = true,
		["pcall"]      = true,
		["xpcall"]     = true,
		["[string]"]   = true,
		["chunk"]      = true,
	}

	-- Strip the name:line suffix that luajit appends in "f;" mode (e.g. "foo:42" → "foo").
	local function frameName(f)
		return (f:gsub(":%d+$", ""))
	end

	lua.profiler.start(state, "fi" .. PROFILER_MS_PER_SAMPLE, function(stack, samples, vmstate)
		total = total + samples
		vmstates[vmstate] = (vmstates[vmstate] or 0) + samples
		if vmstate == "G" or not stack or stack == "" then return end

		-- Accumulate the full stack for flamegraph (clean frame names).
		local cleanParts = {}
		for frame in stack:gmatch("([^;]+)") do
			local name = frameName(frame)
			if name ~= "" and name ~= "?" then
				cleanParts[#cleanParts + 1] = name
			end
		end
		local cleanStack = table.concat(cleanParts, ";")
		if cleanStack ~= "" then
			stacks[cleanStack] = (stacks[cleanStack] or 0) + samples
		end

		-- Hotspot key: first frame that isn't a generic builtin.
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

---@class lde.ExecuteOptions
---@field env          table<string, string>?
---@field args         string[]?
---@field globals      table<string, any>?
---@field packagePath  string?
---@field packageCPath string?
---@field preload      table<string, function>?  modules injected into package.loaded before execution
---@field cwd          string?
---@field profile      boolean?
---@field flamegraph   string?

--- Run Lua source inside a fresh lua-sys guest state.
---
--- The guest receives:
---   • package.path / package.cpath pointing at the package's target/
---   • arg[] populated from opts.args (arg[0] = chunkName)
---   • opts.env entries applied to the host process environment (shared with guest)
---   • opts.preload entries registered as package.preload host callbacks
---   • opts.globals entries written into guest _G
---
---@param source    string  Lua source code to run
---@param chunkName string  Label shown in error traces
---@param opts      lde.ExecuteOptions?
---@return boolean ok
---@return any ...  error message on failure, return values on success
local function executeSource(source, chunkName, opts)
	opts = opts or {}

	-- Change cwd on the host process (guest inherits the same OS environment)
	local oldCwd
	if opts.cwd then
		oldCwd = env.cwd()
		env.chdir(opts.cwd)
	end

	-- Apply env vars; save originals for restore
	local oldEnvVars = {}
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

	-- Fresh isolated state
	local state = lua.new()
	local g     = state:globals()

	-- Set package.path / package.cpath
	local pkg = g.package
	if opts.packagePath  then pkg.path  = opts.packagePath  end
	if opts.packageCPath then pkg.cpath = opts.packageCPath end

	-- Inject preloaded modules directly into package.loaded so require() returns
	-- them immediately — no loader function or cross-boundary callback needed.
	if opts.preload then
		local loaded = pkg.loaded
		for modname, loader in pairs(opts.preload) do
			if type(loader) == "function" then
				loaded[modname] = loader()
			end
		end
	end

	-- Inject extra globals. toLua handles all types including plain host tables.
	if opts.globals then
		for k, v in pairs(opts.globals) do
			if v ~= nil then g[k] = v end
		end
	end

	-- Populate arg[]. toLua coerces the table automatically.
	local args = opts.args or {}
	local argTbl = state:table()
	argTbl[0] = chunkName
	for i, v in ipairs(args) do argTbl[i] = v end
	g.arg = argTbl

	-- Start profiler if requested
	local stopProfiler
	if opts.profile or opts.flamegraph then
		stopProfiler = startProfiler(state)
	end

	-- Execute the script, passing args as varargs so { ... } in the script works
	local chunk = state:load(source, chunkName)
	local ok, a, b, c, d, e, f = pcall(chunk.eval, chunk, unpack(args))

	-- Collect profiling results
	if stopProfiler then
		local counts, vmstates, stacks, total = stopProfiler()
		if opts.profile and lde.verbose then
			printProfileReport(counts, vmstates, total, opts.cwd or env.cwd())
		end
		if opts.flamegraph then
			local title = chunkName and chunkName:match("[^/\\]+$")
			local fgOk, fgErr = lde.flamegraph.write(
				stacks, total, PROFILER_MS_PER_SAMPLE, opts.flamegraph, title)
			if lde.verbose then
				if fgOk then
					ansi.printf("{cyan}Flamegraph written to %s", opts.flamegraph)
				else
					ansi.printf("{red}Flamegraph error: %s", fgErr or "unknown error")
				end
			end
		end
	end

	state:close()
	cleanup()

	return ok, a, b, c, d, e, f
end

---@param scriptPath string
---@param opts lde.ExecuteOptions?
local function executeFile(scriptPath, opts)
	-- Resolve relative paths before reading, using opts.cwd if provided,
	-- so that callers can pass e.g. "./scripts/foo.lua" with a cwd override.
	local resolvedPath = scriptPath
	if opts and opts.cwd and not path.isAbsolute(scriptPath) then
		resolvedPath = path.join(opts.cwd, scriptPath)
	end
	local source, err = fs.read(resolvedPath)
	if not source then
		return false, "Failed to read " .. resolvedPath .. ": " .. (err or "unknown error")
	end
	return executeSource(source, resolvedPath, opts)
end

---@param code string
---@param opts lde.ExecuteOptions?
local function executeString(code, opts)
	return executeSource(code, "-e", opts)
end

--- Run arguments as a Lua interpreter would: zero or more `-e <code>` chunks,
--- then an optional script with its args (or an interactive REPL when the
--- script slot is `-i`). Test harnesses shell out through the lde binary as
--- their Lua interpreter, and depend on the chaining semantics — a prelude
--- chunk (e.g. luacov's runner) must run before the script *in the same
--- state*, and the script must see a rebuilt arg table (arg[0] = script,
--- arg[1..] = its args), matching stock `lua -e ... script args`.
---@param args string[] # the command line after `--lua`
---@param opts lde.ExecuteOptions?
---@return boolean ok
---@return any err
local function executeLuaCLI(args, opts)
	opts = opts or {}

	-- Parse `-e <code>` chunks at the front, then an optional script.
	local eChunks = {}
	local i = 1
	while args[i] == "-e" do
		i = i + 1
		if args[i] == nil then
			return false, "no code given for -e"
		end
		eChunks[#eChunks + 1] = args[i]
		i = i + 1
	end
	---@type string?
	local script = args[i]
	local scriptArgs = {}
	for j = i + 1, #args do scriptArgs[#scriptArgs + 1] = args[j] end
	local interactive = script == "-i"
	if interactive then script = nil end
	if not script and #eChunks == 0 and not interactive then
		return false, "no script or -e chunk given after --lua"
	end

	-- Change cwd on the host process (guest inherits the same OS environment)
	local oldCwd
	if opts.cwd then
		oldCwd = env.cwd()
		env.chdir(opts.cwd)
	end

	-- Apply env vars; save originals for restore
	local oldEnvVars = {}
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

	-- Fresh isolated state
	local state = lua.new()
	local g = state:globals()
	local pkg = g.package
	if opts.packagePath  then pkg.path  = opts.packagePath  end
	if opts.packageCPath then pkg.cpath = opts.packageCPath end

	-- arg[0] = the script path (real Lua semantics); -e chunks see the same
	-- table the script would.
	local argTbl = state:table()
	argTbl[0] = script or "-e"
	for j, v in ipairs(scriptArgs) do argTbl[j] = v end
	g.arg = argTbl

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
		local source, err = fs.read(script)
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
	executeFile   = executeFile,
	executeString = executeString,
	executeLuaCLI = executeLuaCLI,
}
