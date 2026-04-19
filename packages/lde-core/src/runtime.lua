local env = require("env")
local ffi = require("ffi")
local profile = require("jit.profile")
local ansi = require("ansi")
local lde = require("lde-core")

local PROFILER_MS_PER_SAMPLE = 1

local originalCdef = ffi.cdef

local builtinModules = {
	package = true,
	string = true,
	table = true,
	math = true,
	io = true,
	os = true,
	debug = true,
	coroutine = true,
	bit = true,
	jit = true,
	ffi = true,
	["jit.opt"] = true,
	["jit.util"] = true,
	["jit.p"] = true,
	["jit.profile"] = true,
	["string.buffer"] = true
}

---@class lde.ExecuteOptions
---@field env table<string, string>?
---@field args string[]?
---@field globals table<string, any>?
---@field packagePath string?
---@field packageCPath string?
---@field preload table<string, function>?
---@field cwd string?
---@field postexec (fun(): any)?
---@field profile boolean?
---@field flamegraph string?

--- Prints a profile report after a profiled execution.
---@param counts table<string, number>
---@param vmstates table<string, number>
---@param total number
---@param cwd string?
---@param intervalMs number
local function printProfileReport(counts, vmstates, total, cwd, intervalMs)
	local function wln(s) io.write(s .. "\n") end

	if total == 0 then
		wln(ansi.format("  {yellow}Profile: no samples collected"))
		return
	end

	local totalMs = total * intervalMs
	local function fmtTime(ms)
		if ms < 1000 then return string.format("~%dms", ms) end
		return string.format("~%.1fs", ms / 1000)
	end

	local BAR_WIDTH = 20
	local vmColors  = { N = "green", I = "yellow", C = "cyan", G = "red", J = "magenta" }
	local vmLabels  = { N = "JIT compiled", I = "Interpreted", C = "C code", G = "GC", J = "JIT compiler" }
	local vmOrder   = { "N", "I", "C", "G", "J" }

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
		-- Strip target/<name>/ prefix (target dir contains symlinks to src/)
		return (loc:gsub("^target/[^/]+/", ""))
	end

	local sep = ansi.colorize("gray", string.rep("─", 54))

	io.write("\n")
	wln(ansi.format("  {bold}Profile{reset} · {cyan}%s{reset} · {gray}%d samples @ %dms",
		fmtTime(totalMs), total, intervalMs))
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
	for loc, count in pairs(counts) do
		sorted[#sorted + 1] = { loc = loc, count = count }
	end
	table.sort(sorted, function(a, b) return a.count > b.count end)

	for i = 1, math.min(#sorted, 20) do
		local e = sorted[i]
		local pct = e.count / total * 100
		local color = i == 1 and "red" or i <= 3 and "yellow" or "white"
		wln("  "
			.. ansi.colorize(color, string.format("%5.1f%%", pct))
			.. "  " .. ansi.colorize("gray", string.format("%-7s", fmtTime(e.count * intervalMs)))
			.. "  " .. relativize(e.loc))
	end

	io.write("\n")
end

---@param intervalMs number
---@param scriptName string?
---@return (fun(): table<string, number>, table<string, number>, number, table<string, number>)?
---@return string? err
local function startProfiler(intervalMs, scriptName)
	local counts = {}
	local vmstates = {}
	local stacks = {}
	local total = 0
	local mode = "li" .. tostring(intervalMs)

	-- Internal lde function names to skip when falling back to name-based profiling
	local skipNames = {
		commandHandler = true,
		execute = true,
		runFile = true,
		runFileWithLDE = true,
		executeWith = true,
		startProfiler = true
	}

	local started, startErr = pcall(profile.start, mode, function(thread, samples, vmstate)
		total = total + samples
		vmstates[vmstate] = (vmstates[vmstate] or 0) + samples

		if vmstate == "G" then return end

		-- Hotspot key: try ZF (file:line) first. User code has a filesystem path
		-- (contains /). This works for interpreted code; JIT-compiled frames are
		-- invisible to F format, but those get caught by the f fallback below.
		local key
		local okF, locStack = pcall(profile.dumpstack, thread, "ZF;", -100)
		if okF then
			for frame in locStack:gmatch("([^;]+)") do
				if frame:find("/", 1, true) then
					key = frame -- last match = innermost user frame
				end
			end
		end

		-- Fallback for JIT code: f (function name) can see JIT-compiled functions
		-- via JIT trace metadata even when F cannot.
		if not key then
			local okf, name = pcall(profile.dumpstack, thread, "f", 1)
			if okf and name and name ~= "" and name ~= "?" and not skipNames[name] then
				if name == "chunk" and scriptName then
					name = scriptName:match("[^/\\]+$") or name
				end
				key = name
			end
		end

		-- Flamegraph stack: use f; (function names) with full depth. Unlike ZF;,
		-- f reads JIT trace metadata so it traverses both JIT and interpreted frames,
		-- giving real call-chain depth regardless of vmstate.
		local stackKey
		local okFs, fnStack = pcall(profile.dumpstack, thread, "f;", -100)
		if okFs and fnStack and fnStack ~= "" then
			local parts = {}
			for name in fnStack:gmatch("([^;]+)") do
				-- Skip unknown frames, internal lde frames (lde:N, lde-core.x:N),
				-- and C builtins that appear in the chain (pcall, xpcall).
				if name ~= "?" and name ~= "chunk" and not skipNames[name] then
					parts[#parts + 1] = name
				end
			end
			if #parts > 0 then
				stackKey = table.concat(parts, ";")
			end
		end

		if key then
			counts[key] = (counts[key] or 0) + samples
		end
		if stackKey then
			stacks[stackKey] = (stacks[stackKey] or 0) + samples
		end
	end)

	if not started then
		return nil, tostring(startErr)
	end

	return function()
		pcall(profile.stop)
		return counts, vmstates, total, stacks
	end
end

--- Clears non-builtin entries from a table, returning the saved contents.
---@param t table
---@return table saved
local function clearNonBuiltins(t)
	local saved = {}
	for k, v in pairs(t) do
		saved[k] = v
		if not builtinModules[k] then
			t[k] = nil
		end
	end
	return saved
end

--- Restores a table's contents from a saved snapshot.
---@param t table
---@param saved table
local function restore(t, saved)
	for k in pairs(t) do
		t[k] = nil
	end
	for k, v in pairs(saved) do
		t[k] = v
	end
end

---@param compile fun(): function?, string?
---@param opts lde.ExecuteOptions?
---@param scriptName string?
local function executeWith(compile, opts, scriptName)
	opts = opts or {}

	local oldCwd
	if opts.cwd then
		oldCwd = env.cwd()
		env.chdir(opts.cwd)
	end

	local chunk, err = compile()
	if not chunk then
		if oldCwd then env.chdir(oldCwd) end
		return false, err or "Failed to compile"
	end

	local oldPath, oldCPath = package.path, package.cpath

	local oldEnvVars = {}
	if opts.env then
		for k, v in pairs(opts.env) do
			oldEnvVars[k] = env.var(k)
			env.set(k, v)
		end
	end

	local savedLoaded = clearNonBuiltins(package.loaded)
	local savedPreload = clearNonBuiltins(package.preload)

	if opts.preload then
		for k, v in pairs(opts.preload) do
			package.preload[k] = v
		end
	end

	local newG = setmetatable({}, { __index = _G })
	setfenv(chunk, newG)
	package.loaded._G = newG

	local oldLoaders = package.loaders
	local freshLoaders = {}
	for i, loader in ipairs(oldLoaders) do
		freshLoaders[i] = function(modname)
			local result = loader(modname)
			if type(result) == "function" then
				pcall(setfenv, result, newG)
			end
			return result
		end
	end
	package.loaders = freshLoaders

	ffi.cdef = function(def)
		local ok, err = pcall(originalCdef, def)
		if not ok and not string.find(err, "attempt to redefine", 1, true) then
			error(err, 2)
		end
	end

	local originalTmpname = os.tmpname
	os.tmpname = env.tmpfile

	package.path = opts.packagePath or oldPath
	package.cpath = opts.packageCPath or oldCPath

	local stopProfiler
	if opts.profile or opts.flamegraph then
		local profilerErr
		stopProfiler, profilerErr = startProfiler(PROFILER_MS_PER_SAMPLE, scriptName)
		if not stopProfiler then
			for k, v in pairs(oldEnvVars) do env.set(k, v) end
			if oldCwd then env.chdir(oldCwd) end
			ffi.cdef = originalCdef
			os.tmpname = originalTmpname
			restore(package.loaded, savedLoaded)
			restore(package.preload, savedPreload)
			package.loaders = oldLoaders
			package.path, package.cpath = oldPath, oldCPath
			return false, "Failed to start profiler: " .. tostring(profilerErr)
		end
	end

	local function finishProfiler()
		if not stopProfiler then return end
		local counts, vmstates, total, stacks = stopProfiler()
		stopProfiler = nil
		if opts.profile and lde.verbose then
			printProfileReport(counts, vmstates, total, env.cwd(), PROFILER_MS_PER_SAMPLE)
		end
		if opts.flamegraph then
			local fgTitle = scriptName and scriptName:match("[^/\\]+$")
			local ok, err = lde.flamegraph.write(stacks, total, PROFILER_MS_PER_SAMPLE, opts.flamegraph, fgTitle)
			if lde.verbose then
				if ok then
					ansi.printf("{cyan}Flamegraph written to %s", opts.flamegraph)
				else
					ansi.printf("{red}Flamegraph error: %s", err or "unknown error")
				end
			end
		end
	end

	if opts.args then
		arg = opts.args
		arg[0] = scriptName
	end

	local ok, a, b, c, d, e, f = pcall(chunk, unpack(opts.args or {}))

	finishProfiler()

	if ok and opts.postexec then
		ok, a, b, c, d, e, f = pcall(opts.postexec)
	end

	if stopProfiler then
		stopProfiler()
	end

	for k, v in pairs(oldEnvVars) do env.set(k, v) end
	if oldCwd then env.chdir(oldCwd) end

	ffi.cdef = originalCdef
	os.tmpname = originalTmpname
	restore(package.loaded, savedLoaded)
	restore(package.preload, savedPreload)
	package.loaders = oldLoaders
	package.path, package.cpath = oldPath, oldCPath

	return ok, a, b, c, d, e, f
end

---@param scriptPath string
---@param opts lde.ExecuteOptions?
local function executeFile(scriptPath, opts)
	return executeWith(function() return loadfile(scriptPath, "t") end, opts, scriptPath)
end

---@param code string
---@param opts lde.ExecuteOptions?
local function executeString(code, opts)
	return executeWith(function()
		return loadstring("return " .. code, "-e") or loadstring(code, "-e")
	end, opts)
end

return {
	executeFile = executeFile,
	executeString = executeString
}
