const env  = require("env")
const fs   = require("fs")
const ffi  = require("ffi")
const path = require("path")
const ansi = require("ansi")

const runtime = require("lde-core.runtime")

-- Cross-platform sleep used to debounce the file watchers.
local sleep
if jit.os == "Windows" then
	pcall(ffi.cdef, "void Sleep(unsigned long dwMilliseconds);")
	sleep = function(ms) ffi.C.Sleep(ms) end
else
	pcall(ffi.cdef, "int usleep(unsigned int usec);")
	sleep = function(ms) ffi.C.usleep(ms * 1000) end
end

-- Guest-state error markers: RELOAD_MARKER = a relevant file changed mid-run;
-- EXIT_MARKER = os.exit(), treated as "run finished" so watching continues.
local RELOAD_MARKER = "__lde_hot_reload__"
local EXIT_MARKER   = "__lde_exit__"

const BOOTSTRAP = require("lde-core.watchrun.bootstrap")

-- A src/foo.tl change must match the "src:foo.lua" key the guest recorded;
-- mirrors the guest bootstrap's canonicalKey.
---@param key string
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

-- ansi.formatElapsed rounds everything under 100ms to whole milliseconds, so a
-- sub-millisecond reload would read "0ms"; keep µs for those.
---@param seconds number
local function formatReloadTime(seconds)
	if seconds < 0.001 then
		const us = seconds * 1e6
		return us < 10 ? string.format("%.1fµs", us) : string.format("%.0fµs", us)
	end
	if seconds < 1 then return string.format("%.1fms", seconds * 1000) end
	return ansi.formatElapsed(seconds)
end

-- Summarise one --hot reload cycle: patched modules (plus "entry" when the
-- entry point re-ran) and elapsed time. Flushed immediately: control passes to
-- the entry next, which may never return and lose buffered output on kill.
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

--- Run the entry point in a guest state, watching for file changes. "hot" keeps
--- the state and drops changed modules; "watch" recreates it. Runs until killed.
---@param opts lde.WatchOptions
local function run(opts)
	local state, cleanup ---@type lua.State?, fun()?
	local hotStateTbl, reloadFn, checkKeyFn, beginEntryFn, flushAcceptsFn ---@type lua.Table?, function?, function?, function?, function?

	local entryKey = normalizeKey(opts.entry, opts.srcPrefix, opts.targetPrefix)
	-- The entry chunk is never require()d, so it has no module name to report;
	-- the caller's name for it (package/script) is what a summary shows.
	const entryLabel = opts.entryLabel or "entry"

	-- Absolute paths of changed files, drained by the driver between runs.
	local pending = {} ---@type string[]
	-- True only while the entry chunk executes, so a poll cannot fire during the
	-- driver's own guest calls (reload/checkKey).
	local running = false
	-- Re-entrancy guard: checkKey() runs guest code, which may call poll() again.
	local inPoll = false
	-- After a failed run, the next change restarts the app in a fresh state.
	local fullReload = false

	const watchers = {}
	for _, w in ipairs(opts.watchDirs) do
		local dir = w.dir
		if fs.isdir(dir) then
			const watcher = fs.watch(dir, function(_event, name)
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

-- Poll the source tree; false when nothing changed. A program owning its loop
-- calls this (package.hot.poll); a tracked change raises RELOAD_MARKER to unwind.
---@return boolean false
local function poll()
	if inPoll or not running then return false end
	inPoll = true

	for _, watcher in ipairs(watchers) do watcher.poll() end
	if #pending > 0 then
		for i = #pending, 1, -1 do
			local abs = pending[i]
			const relevant = opts.mode == "watch" or fullReload or (checkKeyFn and checkKeyFn(abs))
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
		-- `_` is a real name: without a local it would be a global written on install.
		local _
		state, _, cleanup = opts.createState()

		-- Passed to the bootstrap chunk as varargs; abs() resolves the searcher's
		-- relative paths against the guest cwd.
		const boot = state:load(BOOTSTRAP, "@lde-watchrun")
		local ok, hotState = boot:pcall({
			abs = p -> path.resolve(env.cwd(), p),
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

		const rf = hotState:get("reload") ---@cast rf function
		reloadFn = rf

		const ckf = hotState:get("checkKey") ---@cast ckf function
		checkKeyFn = ckf

		const bef = hotState:get("beginEntry") ---@cast bef function
		beginEntryFn = bef

		const faf = hotState:get("flushAccepts") ---@cast faf function
		flushAcceptsFn = faf

		-- No debug hook: one only fires on interpreted code, so it would disable
		-- JIT for the session. Loop-owning programs call package.hot.poll().
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
		-- "@" label: errors report as path:line instead of the (truncated) source.
		const chunk = state:load(source, "@" .. opts.entry)
		-- Reset the entry's accept registrations; this run re-registers fresh ones.
		if beginEntryFn then beginEntryFn() end
		running = true
		local ok, result = chunk:pcall(unpack(opts.args or {}))
		running = false

		if not ok then
			const msg = tostring(result)
			if msg:find(RELOAD_MARKER, 1, true) then
				return "reload"
			end
			const exitCode = msg:match(EXIT_MARKER .. "([0-9]+)")
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
			-- opts.onError renders Bun-style (source snippet); fall back to a plain line.
			const rendered = opts.onError and opts.onError(tostring(info))
			if not rendered then
				ansi.printf("{red}Error: %s", tostring(info))
			end
			fullReload = true
		elseif result == "exit" and info and info ~= 0 then
			ansi.printf("{yellow}Process exited with code %d", info)
		end
		-- Non-TTY stdout is block-buffered and the driver never exits, so flush or
		-- the tail is lost when killed (or buried under the next run's output).
		io.stdout:flush()
		return result
	end

	-- Drop cached modules for pending changes. Returns whether the entry should
	-- be re-run, the names to report (hot mode), and whether to rebuild the state.
	---@return boolean shouldRun
	---@return string[] reloadedNames
	---@return boolean restart
	local function processPendingChanges()
		const changes = pending
		pending = {}
		if #changes == 0 then return false, {}, false end

		-- --watch and post-failure changes rebuild the state: a module calling
		-- ffi.cdef() at load time cannot be re-run in place (LuaJIT refuses the
		-- duplicate declaration), so an FFI-loaded state can only be replaced.
		if opts.mode == "watch" or fullReload then
			return true, { entryLabel }, true
		end

		local entryChanged = false
		local reloaded = 0
		for i = 1, #changes do
			local key = normalizeKey(changes[i], opts.srcPrefix, opts.targetPrefix)
			if key == entryKey then
				entryChanged = true
			elseif reloadFn then
				reloaded += reloadFn(key)
			end
		end

		local shouldRun = entryChanged or reloaded > 0
		local names = {}
		if shouldRun then
			if reloaded > 0 then
				const lst = hotStateTbl and hotStateTbl:get("lastReloaded") ---@cast lst lua.Table
				if lst then
					for _i, v in lst:ipairs() do names[#names + 1] = v end
				end
			end
			-- This cycle re-runs the entry point, so report it even when no module
			-- was patched instead of leaving the summary empty.
			if entryChanged or #names == 0 then names[#names + 1] = entryLabel end
		end
		return shouldRun, names, false
	end

	if not installState() then return end

	ansi.printf("{cyan}Watching %s for changes...", opts.watchDirs[1].dir)
	-- Flushed for the same reason as the reload summary: the entry runs next.
	io.stdout:flush()
	local result ---@type string?
	result = runAndReport()

	while true do
		-- After a poll-triggered reload the changes are already collected; else
		-- wait. Poll instead of watcher.wait() to keep the inotify fd nonblocking.
		if not (opts.mode == "hot" and result == "reload") then
			while #pending == 0 do
				for _, watcher in ipairs(watchers) do watcher.poll() end
				if #pending == 0 then sleep(50) end
			end
		end

		-- Settle: one save can emit several inotify events (truncate + write [+
		-- rename]); drain the stragglers so one save triggers one reload.
		sleep(30)
		for _, watcher in ipairs(watchers) do watcher.poll() end

		-- Clock starts after the change is known and settled: it measures the
		-- reload (patching, rebuild, callbacks), not the debounce or the wait.
		local reloadStartedAt = ansi.now()
		local shouldRun, reloadedNames, restart = processPendingChanges()
		if shouldRun then
			ansi.clearScreen()

			if opts.mode == "watch" then
				ansi.printf("{cyan}Change detected, restarting...")
			end

			const buildOk = opts.preReload == nil or opts.preReload()
			if not buildOk then
				-- Keep the previous state and retry on the next change; the queued
				-- accept notifications describe a reload that never happened, so drop them.
				if flushAcceptsFn then flushAcceptsFn(false) end
				if opts.mode == "hot" then
					reportHotReload(reloadedNames, ansi.now() - reloadStartedAt, false)
				end
				result = nil
			else
				if restart then
					-- Rebuild the state rather than patch it; the notifications
					-- queued against the old one go with its modules.
					disposeState()
					if not installState() then return end
					-- Only now, so a build failure above leaves the next change on the restart path.
					fullReload = false
				elseif flushAcceptsFn then
					-- After clearScreen() and the rebuild, before the entry re-runs.
					flushAcceptsFn(true)
				end
				-- Reported last so the duration covers the whole reload, and before
				-- runEntry() so it stays above the new run's output.
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

-- formatReloadTime is exported for its unit test: a real reload's duration is
-- the machine's to choose, not the test's.
return { run = run, bootstrap = BOOTSTRAP, formatReloadTime = formatReloadTime }
