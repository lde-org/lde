local env  = require("env")
local fs   = require("fs")
local ffi  = require("ffi")
local path = require("path")
local ansi = require("ansi")

local runtime = require("lde-core.runtime")

-- Cross-platform sleep used to debounce the file watchers.
local sleep
if jit.os == "Windows" then
	pcall(ffi.cdef, "void Sleep(unsigned long dwMilliseconds);")
	sleep = function(ms) ffi.C.Sleep(ms) end
else
	pcall(ffi.cdef, "int usleep(unsigned int usec);")
	sleep = function(ms) ffi.C.usleep(ms * 1000) end
end

-- Error markers raised inside the guest state:
--   RELOAD_MARKER — a relevant file changed while the app was running; the
--                   driver catches it, invalidates the affected modules and
--                   re-runs the entry point.
--   EXIT_MARKER   — the app called os.exit(); treat it as "run finished" and
--                   keep watching instead of killing the whole process.
local RELOAD_MARKER = "__lde_hot_reload__"
local EXIT_MARKER   = "__lde_exit__"

-- Count-hook interval: the guest runs at most this many VM instructions
-- between watcher polls. Larger values reduce overhead, smaller values make
-- reload detection snappier. Hooks only fire on interpreted code, so the
-- guest JIT is disabled while one is installed (same tradeoff as a debugger).
local HOOK_INTERVAL = 10000

-- Guest-side infrastructure for `lde run --hot` / `lde run --watch`.
-- Evaluated once per guest state, before the entry point runs. It:
--   1. wraps the Lua file searcher to record which source file backs each module,
--   2. wraps require() to record module → module dependency edges,
--   3. wraps os.exit() so it aborts the run instead of the whole process,
--   4. returns reload() / reloadAll() / checkKey() on the module table.
local BOOTSTRAP = [==[
-- The config table (prefixes, entry key, abs() helper, exit marker) is passed
-- as the first vararg by the driver — same convention as lua-sys chunks.
local hot = ...

local M = {
	fileModules = {}, -- normalized source key -> { [modname] = true }
	moduleFile  = {}, -- modname -> normalized source key
	dependents  = {}, -- modname -> { [dependent] = true }
	lastReloaded = {},
}

-- Map a module's file path to a reload key. A package's own modules live
-- under target/<name>/ (a copy of src/, or a symlink to it), so they are
-- keyed by their src/ identity: "src:foo.lua". Everything else (deps,
-- stdlib, loose files) keeps its absolute path.
---@param p string
---@return string
local function normKey(p)
	local t = hot.targetPrefix
	if t and p:sub(1, #t) == t then
		return "src:" .. p:sub(#t + 1)
	end
	local s = hot.srcPrefix
	if s and p:sub(1, #s) == s then
		return "src:" .. p:sub(#s + 1)
	end
	return p
end

-- Wrap the Lua file searcher so every freshly loaded module records which
-- source file backs it. LuaJIT's searcher only returns the loader, so the
-- file is recovered from the loader's debug source ("@<path>"). C modules
-- are left alone (they cannot be unloaded).
local searchers = package.searchers or package.loaders
local origLuaSearcher = searchers[2]
searchers[2] = function(name)
	local loader, file = origLuaSearcher(name)
	if type(loader) == "function" then
		local info = debug.getinfo(loader, "S")
		local src = info and info.source
		if src and src:sub(1, 1) == "@" then
			local key = normKey(hot.abs(src:sub(2)))
			M.moduleFile[name] = key
			local set = M.fileModules[key]
			if not set then set = {}; M.fileModules[key] = set end
			set[name] = true
		end
	end
	return loader, file
end

-- Wrap require() to record dependency edges (caller -> required module) so
-- invalidating a module also invalidates everything that transitively
-- depends on it.
local origRequire = require
local loadStack = {}
require = function(name)
	if type(name) ~= "string" then return origRequire(name) end
	local caller = loadStack[#loadStack]
	loadStack[#loadStack + 1] = name
	local ok, result = pcall(origRequire, name)
	loadStack[#loadStack] = nil
	if not ok then error(result, 0) end
	if caller and caller ~= name then
		local deps = M.dependents[name]
		if not deps then deps = {}; M.dependents[name] = deps end
		deps[caller] = true
	end
	return result
end

-- os.exit() would terminate the whole process (the guest shares it with
-- lde). Intercept it: the driver turns the marker into "run finished" and
-- keeps watching, so a one-shot script gets re-run on the next change.
os.exit = function(code)
	if code == true then code = 0 end
	error(hot.exitMarker .. tostring(code or 0), 0)
end

---@param names table<string, boolean>
---@param out table<string, boolean>
local function collect(names, out)
	for name in pairs(names) do
		if not out[name] then
			out[name] = true
			local deps = M.dependents[name]
			if deps then collect(deps, out) end
		end
	end
end

---@param name string
local function drop(name)
	package.loaded[name] = nil
	local key = M.moduleFile[name]
	if key then
		local set = M.fileModules[key]
		if set then
			set[name] = nil
			if next(set) == nil then M.fileModules[key] = nil end
		end
		M.moduleFile[name] = nil
	end
	M.dependents[name] = nil
end

-- Invalidate the modules backed by a changed source file, plus everything
-- that transitively depends on them. Returns the number of modules dropped.
---@param changedKey string
---@return integer
function M.reload(changedKey)
	local names = M.fileModules[changedKey]
	if not names or next(names) == nil then return 0 end
	local out = {}
	collect(names, out)
	local list = {}
	for name in pairs(out) do
		list[#list + 1] = name
		drop(name)
	end
	table.sort(list)
	M.lastReloaded = list
	return #list
end

-- Drop every tracked module. Used after a failed run so the next reload
-- starts from a clean slate.
function M.reloadAll()
	local list = {}
	for name in pairs(M.moduleFile) do list[#list + 1] = name end
	for i, name in ipairs(list) do drop(name) end
	table.sort(list)
	M.lastReloaded = list
	return #list
end

-- True when a changed file maps to a tracked module or the entry point.
---@param absPath string
---@return boolean
function M.checkKey(absPath)
	local key = normKey(absPath)
	return key == hot.entryKey or M.fileModules[key] ~= nil
end

return M
]==]

--- Map an absolute file path to a reload key. Mirrors the guest's normKey.
---@param p string
---@param srcPrefix string?
---@param targetPrefix string?
---@return string
local function normalizeKey(p, srcPrefix, targetPrefix)
	if targetPrefix and p:sub(1, #targetPrefix) == targetPrefix then
		return "src:" .. p:sub(#targetPrefix + 1)
	end
	if srcPrefix and p:sub(1, #srcPrefix) == srcPrefix then
		return "src:" .. p:sub(#srcPrefix + 1)
	end
	return p
end

---@class lde.WatchOptions
---@field mode "hot"|"watch"          # hot = same state, patch package.loaded; watch = fresh state per run
---@field createState fun(): lua.State, lua.Table, fun()  # state, globals, cleanup
---@field entry string                # absolute path to the entry script, re-read every run
---@field args string[]?              # [0] = entry, [1..] = script args; re-passed on each run
---@field watchDirs { dir: string, recursive: boolean }[]
---@field srcPrefix string?           # package src dir + path.separator
---@field targetPrefix string?        # package target/<name> dir + path.separator
---@field preReload fun()?              # runs before each reload (e.g. rebuild); false = skip the re-run

--- Run the entry point in a guest state, watching for file changes. In "hot"
--- mode the state survives reloads and only the changed modules' package.loaded
--- entries are dropped; in "watch" mode the state is recreated fresh. Runs
--- until the process is killed (Ctrl+C).
---@param opts lde.WatchOptions
local function run(opts)
	local state, cleanup ---@type lua.State?, fun()?
	local hotStateTbl, reloadFn, reloadAllFn, checkKeyFn ---@type lua.Table?, function?, function?, function?

	local entryKey = normalizeKey(opts.entry, opts.srcPrefix, opts.targetPrefix)

	-- Absolute paths of changed files, drained by the driver between runs.
	local pending = {} ---@type string[]
	-- True only while the entry chunk is executing: the hook is what gives the
	-- driver control while the app runs, so it must not fire during the
	-- driver's own guest calls (reload/checkKey).
	local running = false
	-- Re-entrancy guard: checkKey() executes guest code, which fires this
	-- hook again from inside itself.
	local inHook = false
	-- Set after a failed run: the next reload drops every tracked module.
	local fullReload = false

	local watchers = {}
	for _, w in ipairs(opts.watchDirs) do
		local dir = w.dir
		if fs.isdir(dir) then
			local watcher = fs.watch(dir, function(_event, name)
				if name and name ~= "" then pending[#pending + 1] = path.join(dir, name) end
			end, { recursive = w.recursive })
			if watcher then
				watchers[#watchers + 1] = watcher
			else
				ansi.printf("{red}Failed to watch: %s", dir)
			end
		end
	end
	if #watchers == 0 then
		ansi.printf("{red}Nothing to watch (no watchable directory found)")
		return
	end

	-- Count hook: fires every HOOK_INTERVAL guest instructions. Polls the
	-- watchers; when a relevant change is pending it aborts the running app
	-- with RELOAD_MARKER so the driver can invalidate and re-run. Irrelevant
	-- churn (logs, caches) is dropped here so it can't interrupt the app.
	local function hook()
		if inHook or not running then return end
		inHook = true

		for _, watcher in ipairs(watchers) do watcher.poll() end
		if #pending > 0 then
			for i = #pending, 1, -1 do
				local abs = pending[i]
				local relevant = opts.mode == "watch" or fullReload or (checkKeyFn and checkKeyFn(abs))
				if relevant then
					-- Leave pending intact: the driver processes it after the
					-- error unwinds the guest stack.
					inHook = false
					error(RELOAD_MARKER, 0)
				end
				pending[i] = pending[#pending]
				pending[#pending] = nil
			end
		end
		inHook = false
	end

	local function installState()
		state, _, cleanup = opts.createState()

		-- The bootstrap closes over this config; it's passed as the chunk's
		-- varargs. abs() resolves the searcher's relative file paths against
		-- the guest cwd.
		local boot = state:load(BOOTSTRAP, "@lde-watchrun")
		local ok, hotState = boot:pcall({
			abs = function(p) return path.resolve(env.cwd(), p) end,
			srcPrefix = opts.srcPrefix,
			targetPrefix = opts.targetPrefix,
			entryKey = entryKey,
			exitMarker = EXIT_MARKER,
		})
		if not ok then
			ansi.printf("{red}Failed to install watch hooks: %s", tostring(hotState))
			state:close()
			if cleanup then cleanup() end
			state, cleanup = nil, nil
			return false
		end

		---@cast hotState lua.Table
		hotStateTbl = hotState

		local rf = hotState:get("reload") ---@cast rf function
		reloadFn = rf

		local raf = hotState:get("reloadAll") ---@cast raf function
		reloadAllFn = raf

		local ckf = hotState:get("checkKey") ---@cast ckf function
		checkKeyFn = ckf

		-- Disables the guest JIT for the whole session (hooks only fire on
		-- interpreted code) — the price of being able to interrupt the app.
		state:setHook(hook, "count", HOOK_INTERVAL)
		return true
	end

	local function disposeState()
		if state then
			state:close()
			state = nil
		end
		if cleanup then
			cleanup()
			cleanup = nil
		end
	end

	local function runEntry() ---@cast state lua.State
		local source, chunkName, readErr = runtime.readCompiledFile(opts.entry)
		if not source then
			return "error", readErr
		end
		local chunk = state:load(source, chunkName)
		running = true
		local ok, result = chunk:pcall(unpack(opts.args or {}))
		running = false

		if not ok then
			local msg = tostring(result)
			if msg:find(RELOAD_MARKER, 1, true) then
				return "reload"
			end
			local exitCode = msg:match(EXIT_MARKER .. "([0-9]+)")
			if exitCode then
				return "exit", tonumber(exitCode)
			end
			return "error", result
		end
		return "ok"
	end

	local function runAndReport()
		local result, info = runEntry()
		if result == "error" then
			ansi.printf("{red}Error: %s", tostring(info))
			fullReload = true
		elseif result == "exit" and info and info ~= 0 then
			ansi.printf("{yellow}Process exited with code %d", info)
		end
		-- Non-TTY stdout is block-buffered and the driver never exits, so
		-- flush after every run or the tail of the output is lost when the
		-- process is killed (or buried under the next run's output).
		io.stdout:flush()
		return result
	end

	-- Drop cached modules for the pending changes. Returns whether the entry
	-- point should be re-run plus the reloaded module names (hot mode only),
	-- so the caller can print them after clearing the screen.
	---@return boolean shouldRun
	---@return string[] reloadedNames
	local function processPendingChanges()
		local changes = pending
		pending = {}
		if #changes == 0 then return false, {} end

		if opts.mode == "watch" then
			return true, {}
		end

		local entryChanged = false
		local reloaded = 0
		for i = 1, #changes do
			local key = normalizeKey(changes[i], opts.srcPrefix, opts.targetPrefix)
			if key == entryKey then
				entryChanged = true
			elseif reloadFn then
				reloaded = reloaded + reloadFn(key)
			end
		end

		local shouldRun = entryChanged or reloaded > 0 or fullReload
		local names = {}
		if shouldRun then
			if fullReload then
				fullReload = false
				reloaded = reloaded + (reloadAllFn and reloadAllFn() or 0)
			end
			if reloaded > 0 then
				local lst = hotStateTbl and hotStateTbl:get("lastReloaded") ---@cast lst lua.Table
				if lst then
					for _i, v in lst:ipairs() do names[#names + 1] = v end
				end
			end
		end
		return shouldRun, names
	end

	if not installState() then return end

	ansi.printf("{cyan}Watching %s for changes...", opts.watchDirs[1].dir)
	local result ---@type string?
	result = runAndReport()

	while true do
		-- If the app was interrupted by the hook, the pending changes are
		-- already collected; otherwise wait for a change. Polling instead of
		-- watcher.wait() keeps the inotify fd nonblocking, so the settle and
		-- hook polls below never block (fs.watch's wait() leaves it blocking
		-- on Linux).
		if not (opts.mode == "hot" and result == "reload") then
			while #pending == 0 do
				for _, watcher in ipairs(watchers) do watcher.poll() end
				if #pending == 0 then sleep(50) end
			end
		end

		-- Settle: a single editor save can emit several inotify events
		-- (truncate + write [+ rename]); let the stragglers arrive, then drain
		-- them so one save triggers one reload.
		sleep(30)
		for _, watcher in ipairs(watchers) do watcher.poll() end

		local shouldRun, reloadedNames = processPendingChanges()
		if shouldRun then
			ansi.clearScreen()

			if opts.mode == "hot" then
				if #reloadedNames > 0 then
					ansi.printf("{cyan}Reloaded: {yellow}%s", table.concat(reloadedNames, ", "))
				end
			else
				ansi.printf("{cyan}Change detected, restarting...")
			end

			local buildOk = opts.preReload == nil or opts.preReload()
			if not buildOk then
				-- Keep the previous state; the next change retries.
				result = nil
			else
				if opts.mode == "watch" then
					disposeState()
					if not installState() then return end
				end
				result = runAndReport()
			end
		else
			result = nil
		end
	end
end

return { run = run, bootstrap = BOOTSTRAP }
