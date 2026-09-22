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

-- Guest-side infrastructure for `lde run --hot` / `lde run --watch`.
-- Evaluated once per guest state, before the entry point runs. It:
--   1. wraps the Lua file searcher to record which source file backs each module,
--   2. wraps require() to record module → module dependency edges,
--   3. wraps os.exit() so it aborts the run instead of the whole process,
--   4. exposes package.hot (--hot only) so modules can register accept()
--      callbacks that fire when a module is reloaded, and poll() so a program
--      that owns its own loop can ask for one,
--   5. returns reload() / reloadAll() / checkKey() / beginEntry() /
--      flushAccepts() on the module table.
local BOOTSTRAP = [==[
-- The config table (prefixes, entry key, abs() helper, exit marker) is passed
-- as the first vararg by the driver — same convention as lua-sys chunks.
local hot = ...

local M = {
	fileModules = {}, -- normalized source key -> { [modname] = true }
	moduleFile  = {}, -- modname -> normalized source key
	dependents  = {}, -- modname -> { [dependent] = true }
	lastReloaded = {},
	accepts     = {}, -- owner -> { fn, ... } (see acceptOwner)

	-- Notifications queued by reload()/reloadAll() and fired by flushAccepts()
	-- once the driver has cleared the screen and rebuilt (see flushAccepts).
	-- The sets de-duplicate: one cycle can invalidate several batches, and a
	-- callback or a module name can appear in more than one of them.
	pendingCallbacks   = {},
	pendingNames       = {},
	pendingCallbackSet = {},
	pendingNameSet     = {},
}

-- Owner slot for callbacks registered by the entry point: the entry chunk is
-- never loaded through require(), so it has no module name to be keyed by.
local ENTRY_OWNER = "@entry"

-- A Teal/Moonscript source compiles to a .lua module under target/, so a
-- change to src/foo.tl must invalidate the loaded src/foo.lua: key both by
-- the compiled name.
---@param key string
---@return string
local function canonicalKey(key)
	if key:sub(1, 4) == "src:" then
		return (key:gsub("%.tl$", ".lua"):gsub("%.moon$", ".lua"))
	end
	return key
end

-- Map a module's file path to a reload key. A package's own modules live
-- under target/<name>/ (a copy of src/, or a symlink to it), so they are
-- keyed by their src/ identity: "src:foo.lua". Everything else (deps,
-- stdlib, loose files) keeps its absolute path.
---@param p string
---@return string
local function normKey(p)
	local t = hot.targetPrefix
	if t and p:sub(1, #t) == t then
		return canonicalKey("src:" .. p:sub(#t + 1))
	end
	local s = hot.srcPrefix
	if s and p:sub(1, #s) == s then
		return canonicalKey("src:" .. p:sub(#s + 1))
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

-- The owner of an accept() registration: the module whose source file contains
-- the call, or the entry point when the file backs no required module. Read
-- from the caller's debug source rather than the load stack, so a callback
-- registered from a function that runs long after load is still attributed to
-- the module it was defined in.
---@param level integer
---@return string
local function acceptOwner(level)
	local info = debug.getinfo(level, "S")
	local src = info and info.source
	if src and src:sub(1, 1) == "@" then
		local key = normKey(hot.abs(src:sub(2)))
		if key ~= hot.entryKey then
			local names = M.fileModules[key]
			if names then
				for name in pairs(names) do return name end
			end
		end
	end
	return ENTRY_OWNER
end

-- Register fn to be called with the require() path of every module that gets
-- reloaded. A registration belongs to the module that made the call: it is
-- dropped with that module and re-made when the module reloads, so callbacks
-- held by stale module instances cannot pile up across reloads.
---@param fn fun(name: string)
local function accept(fn)
	if type(fn) ~= "function" then
		error("package.hot.accept expects a function, got " .. type(fn), 2)
	end
	local owner = acceptOwner(2)
	local list = M.accepts[owner]
	if not list then
		list = {}
		M.accepts[owner] = list
	end
	list[#list + 1] = fn
end

-- Only --hot exposes package.hot: --watch recreates the state on every change,
-- so there is no live module to accept a reload.
--
-- accept(fn)  registers a callback for every module that gets reloaded.
-- poll()      checks the source tree for changes; a program that owns its own
--             loop calls it from the loop to be reloadable. It returns false
--             when nothing changed, and otherwise aborts the current run so
--             the driver can reload and re-run the entry point.
if hot.mode == "hot" then
	package.hot = { accept = accept, poll = hot.poll }
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
	M.accepts[name] = nil
end

-- Every registered callback, flattened. Snapshotting before the drops lets a
-- module that is itself reloaded hear about it: its own registration is still
-- in the snapshot even though drop() removes it right after.
---@return function[]
local function snapshotAccepts()
	local out = {}
	for _owner, list in pairs(M.accepts) do
		for i = 1, #list do out[#out + 1] = list[i] end
	end
	return out
end

-- Hold a reload's callbacks and module names until the driver is ready to
-- deliver them. Firing here would be wrong twice over: the driver clears the
-- screen right after the invalidation (wiping anything a callback printed),
-- and a build.lua package has not rebuilt target/ yet (so a callback that
-- requires the changed module would cache stale code).
---@param callbacks function[]
---@param names string[]
local function queue(callbacks, names)
	for i = 1, #callbacks do
		local fn = callbacks[i]
		if not M.pendingCallbackSet[fn] then
			M.pendingCallbackSet[fn] = true
			M.pendingCallbacks[#M.pendingCallbacks + 1] = fn
		end
	end
	for i = 1, #names do
		local name = names[i]
		if not M.pendingNameSet[name] then
			M.pendingNameSet[name] = true
			M.pendingNames[#M.pendingNames + 1] = name
		end
	end
end

-- A failed callback must not take down the reload (or the driver, which calls
-- this outside any pcall).
---@param callbacks function[]
---@param names string[]
local function notify(callbacks, names)
	for i = 1, #names do
		local name = names[i]
		for j = 1, #callbacks do
			local ok, err = pcall(callbacks[j], name)
			if not ok then
				io.stderr:write("[lde --hot] package.hot.accept callback failed for '", name, "': ", tostring(err), "\n")
			end
		end
	end
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
	for name in pairs(out) do list[#list + 1] = name end
	table.sort(list)
	local callbacks = snapshotAccepts()
	for i = 1, #list do drop(list[i]) end
	M.lastReloaded = list
	queue(callbacks, list)
	return #list
end

-- Drop every tracked module. Used after a failed run so the next reload
-- starts from a clean slate.
function M.reloadAll()
	local list = {}
	for name in pairs(M.moduleFile) do list[#list + 1] = name end
	table.sort(list)
	local callbacks = snapshotAccepts()
	for i, name in ipairs(list) do drop(name) end
	M.lastReloaded = list
	queue(callbacks, list)
	return #list
end

-- Deliver the notifications queued by reload()/reloadAll(). The driver calls
-- this once per reload cycle, after the screen is cleared and target/ is
-- rebuilt but before the entry point re-runs, so a callback both prints
-- visibly and require()s the fresh module.
--
-- isApplied is false when the cycle's rebuild failed: nothing was actually
-- reloaded, so the queue is drained instead of fired.
---@param isApplied boolean
function M.flushAccepts(isApplied)
	local callbacks, names = M.pendingCallbacks, M.pendingNames
	if #names == 0 then return 0 end
	M.pendingCallbacks, M.pendingNames = {}, {}
	M.pendingCallbackSet, M.pendingNameSet = {}, {}
	if not isApplied then return 0 end
	notify(callbacks, names)
	return #names
end

-- Called by the driver before each entry run: the entry re-registers its
-- accept callbacks on every run, so its slot is reset first to keep the list
-- from stacking up duplicates.
function M.beginEntry()
	M.accepts[ENTRY_OWNER] = nil
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

-- Teal/Moonscript sources compile to .lua under target/, so a src/foo.tl
-- change must match the "src:foo.lua" key the guest recorded. Mirrors the
-- guest bootstrap's canonicalKey.
---@param key string
---@return string
local function canonicalKey(key)
	if key:sub(1, 4) == "src:" then
		return (key:gsub("%.tl$", ".lua"):gsub("%.moon$", ".lua"))
	end
	return key
end

--- Map an absolute file path to a reload key. Mirrors the guest's normKey.
---@param p string
---@param srcPrefix string?
---@param targetPrefix string?
---@return string
local function normalizeKey(p, srcPrefix, targetPrefix)
	if targetPrefix and p:sub(1, #targetPrefix) == targetPrefix then
		return canonicalKey("src:" .. p:sub(#targetPrefix + 1))
	end
	if srcPrefix and p:sub(1, #srcPrefix) == srcPrefix then
		return canonicalKey("src:" .. p:sub(#srcPrefix + 1))
	end
	return p
end

---@class lde.WatchOptions
---@field mode "hot"|"watch"          # hot = same state, patch package.loaded; watch = fresh state per run
---@field createState fun(): lua.State, lua.Table, fun()  # state, globals, cleanup
---@field entry string                # absolute path to the entry script, re-read every run
---@field entryLabel string?           # how a re-run of the entry point is named in reload summaries (default "entry")
---@field args string[]?              # [0] = entry, [1..] = script args; re-passed on each run
---@field watchDirs { dir: string, recursive: boolean }[]
---@field srcPrefix string?           # package src dir + path.separator
---@field targetPrefix string?        # package target/<name> dir + path.separator
---@field preReload fun()?              # runs before each reload (e.g. rebuild); false = skip the re-run
---@field onError fun(err: string): boolean? # renders a run error Bun-style; return true when printed

-- Hot reloads are short by nature — patching a module with no rebuild takes
-- microseconds — so a reload below a millisecond keeps its own unit instead of
-- being rounded away: ansi.formatElapsed reports everything under 100ms as
-- whole milliseconds, which reads as "0ms" for exactly that case.
---@param seconds number
local function formatReloadTime(seconds)
	if seconds < 0.001 then
		local us = seconds * 1e6
		return us < 10 ? string.format("%.1fµs", us) : string.format("%.0fµs", us)
	end
	if seconds < 1 then return string.format("%.1fms", seconds * 1000) end
	return ansi.formatElapsed(seconds)
end

-- Summarise one --hot reload cycle: the modules that were patched (plus "entry"
-- when the entry point itself re-ran) and how long the reload took.
--
-- Every cycle that reloads prints exactly one of these. A change that only
-- touches the entry point patches no module, so a summary built from module
-- names alone would come out empty and hide a reload that did happen.
--
-- The line is flushed immediately: the entry point is handed control right
-- after it, and a program that owns its loop (package.hot.poll) may never hand
-- it back, so the bytes would otherwise sit in the stdout buffer until the next
-- reload interrupts the run — or be lost entirely when the process is killed.
---@param names string[]
---@param elapsed number
---@param isApplied boolean
local function reportHotReload(names, elapsed, isApplied)
	local took = formatReloadTime(elapsed)
	if not isApplied then
		ansi.printf("{red}Hot reload failed {gray}(%s)", took)
	else
		ansi.printf("{cyan}Reloaded: {yellow}%s {gray}(%s)", table.concat(names, ", "), took)
	end
	io.stdout:flush()
end

--- Run the entry point in a guest state, watching for file changes. In "hot"
--- mode the state survives reloads and only the changed modules' package.loaded
--- entries are dropped; in "watch" mode the state is recreated fresh. Runs
--- until the process is killed (Ctrl+C).
---@param opts lde.WatchOptions
local function run(opts)
	local state, cleanup ---@type lua.State?, fun()?
	local hotStateTbl, reloadFn, reloadAllFn, checkKeyFn, beginEntryFn, flushAcceptsFn ---@type lua.Table?, function?, function?, function?, function?, function?

	local entryKey = normalizeKey(opts.entry, opts.srcPrefix, opts.targetPrefix)
	-- What a reload of the entry point itself is called in a summary: the entry
	-- chunk is never loaded through require(), so it has no module name to
	-- report, and the caller's name for it (the package, the script file) is
	-- what its sources are known by.
	local entryLabel = opts.entryLabel or "entry"

	-- Absolute paths of changed files, drained by the driver between runs.
	local pending = {} ---@type string[]
	-- True only while the entry chunk is executing. The app is what gives the
	-- driver control (by returning, or by calling package.hot.poll()), so a
	-- poll must not fire during the driver's own guest calls (reload/checkKey).
	local running = false
	-- Re-entrancy guard: checkKey() executes guest code, which may call poll()
	-- again from inside itself.
	local inPoll = false
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

-- Poll the source tree for changes and return false when there was nothing to
-- do. A program that owns its own loop calls this from it (see
-- package.hot.poll); when a tracked file changed it raises RELOAD_MARKER
-- instead of returning, which unwinds the run so the driver can reload and
-- re-run the entry point.
---@return boolean false
local function poll()
	if inPoll or not running then return false end
	inPoll = true

	for _, watcher in ipairs(watchers) do watcher.poll() end
	if #pending > 0 then
		for i = #pending, 1, -1 do
			local abs = pending[i]
			local relevant = opts.mode == "watch" or fullReload or (checkKeyFn and checkKeyFn(abs))
			if relevant then
				-- Leave pending intact: the driver processes it after the
				-- error unwinds the guest stack.
				inPoll = false
				error(RELOAD_MARKER, 0)
			end
			pending[i] = pending[#pending]
			pending[#pending] = nil
		end
	end
	inPoll = false
	return false
end

	local function installState()
		state, _, cleanup = opts.createState()

		-- The bootstrap closes over this config; it's passed as the chunk's
		-- varargs. abs() resolves the searcher's relative file paths against
		-- the guest cwd.
		local boot = state:load(BOOTSTRAP, "@lde-watchrun")
		local ok, hotState = boot:pcall({
			abs = function(p) return path.resolve(env.cwd(), p) end,
			poll = poll,
			mode = opts.mode,
			srcPrefix = opts.srcPrefix,
			targetPrefix = opts.targetPrefix,
			entryKey = entryKey,
			exitMarker = EXIT_MARKER,
		})
		if not ok then
			ansi.printf("{red}Failed to install watch support: %s", tostring(hotState))
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

		local bef = hotState:get("beginEntry") ---@cast bef function
		beginEntryFn = bef

		local faf = hotState:get("flushAccepts") ---@cast faf function
		flushAcceptsFn = faf

		-- No debug hook is installed: a hook only fires on interpreted code, so
		-- keeping one would mean turning the guest JIT off for the whole
		-- session. Without it a program that never returns control cannot be
		-- interrupted (same as bun --hot); programs that own a loop call
		-- package.hot.poll() to be reloadable.
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
		local source, readErr = runtime.readCompiledFile(opts.entry)
		if not source then
			return "error", readErr
		end
		-- "@" chunk label: LuaJIT reports file-backed errors as path:line.
		-- A nil label would fall back to the source text (truncated).
		local chunk = state:load(source, "@" .. opts.entry)
		-- Resets the entry's package.hot.accept registrations: this run
		-- re-registers them, and the previous run's closures are stale.
		if beginEntryFn then beginEntryFn() end
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
			-- The caller can render the error Bun-style (source snippet +
			-- at path:line) via opts.onError; fall back to a plain line.
			local rendered = opts.onError and opts.onError(tostring(info))
			if not rendered then
				ansi.printf("{red}Error: %s", tostring(info))
			end
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
	-- point should be re-run plus the names to report for it (hot mode only):
	-- the modules that were patched, and "entry" when the entry point re-ran.
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
			-- Every cycle that gets here re-runs the entry point, so a cycle
			-- that patched no module still reports what restarted instead of
			-- leaving the summary empty.
			if entryChanged or #names == 0 then names[#names + 1] = entryLabel end
		end
		return shouldRun, names
	end

	if not installState() then return end

	ansi.printf("{cyan}Watching %s for changes...", opts.watchDirs[1].dir)
	-- Flushed for the same reason as the reload summary: the entry point runs
	-- next and may never return, so a redirected stdout would hold this banner
	-- (and the app's own output) until then.
	io.stdout:flush()
	local result ---@type string?
	result = runAndReport()

	while true do
		-- If the app asked for a reload (returned, or raised from
		-- package.hot.poll()), the pending changes are already collected;
		-- otherwise wait for one. Polling instead of watcher.wait() keeps the
		-- inotify fd nonblocking, so the settle and poll calls below never
		-- block (fs.watch's wait() leaves it blocking on Linux).
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

		-- The reload clock starts once the change is known and the watchers have
		-- settled: it measures the reload itself (patching, rebuild, accept
		-- callbacks), not the debounce or the wait for the loop's next poll.
		local reloadStartedAt = ansi.now()
		local shouldRun, reloadedNames = processPendingChanges()
		if shouldRun then
			ansi.clearScreen()

			if opts.mode == "watch" then
				ansi.printf("{cyan}Change detected, restarting...")
			end

			local buildOk = opts.preReload == nil or opts.preReload()
			if not buildOk then
				-- Keep the previous state; the next change retries. The queued
				-- package.hot.accept notifications describe a reload that never
				-- happened, so they are dropped with it.
				if flushAcceptsFn then flushAcceptsFn(false) end
				if opts.mode == "hot" then
					reportHotReload(reloadedNames, ansi.now() - reloadStartedAt, false)
				end
				result = nil
			else
				if opts.mode == "watch" then
					disposeState()
					if not installState() then return end
				end
				-- After clearScreen() (so callback output survives) and after
				-- the rebuild, but before the entry re-runs.
				if flushAcceptsFn then flushAcceptsFn(true) end
				-- Reported last, so the duration covers everything the reload
				-- did, and before runEntry(), so it stays above the new run's
				-- output rather than being buried under it.
				if opts.mode == "hot" then
					reportHotReload(reloadedNames, ansi.now() - reloadStartedAt, true)
				end
				result = runAndReport()
			end
		else
			result = nil
		end
	end
end

-- formatReloadTime is exported for its unit test: which unit a reload reads in
-- depends on how long it took, and a real reload's duration is the machine's,
-- not the test's, to choose.
return { run = run, bootstrap = BOOTSTRAP, formatReloadTime = formatReloadTime }
