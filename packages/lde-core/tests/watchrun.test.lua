-- Unit tests for the hot-reload dependency graph installed by watchrun's
-- BOOTSTRAP chunk (the guest-side module tracking + reload machinery). The
-- end-to-end --hot/--watch loops are covered by packages/lde/tests/hot.test.lua
-- through child processes; here the bootstrap runs in-process in a real guest
-- state so reload/reloadAll/checkKey are asserted directly.
local test = require("lde-test")

local lde = require("lde-core")
local watchrun = require("lde-core.watchrun")

local fs = require("fs")
local env = require("env")
local path = require("path")

local tmpBase = path.normalize(path.join(env.tmpdir(), "lde-watchrun-tests"))
-- Normalized: on macOS CI, TMPDIR has a trailing slash, so the raw join would
-- contain a double separator that path.resolve (used by the bootstrap's abs())
-- collapses — making recorded keys mismatch the test's own paths.
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

-- Guest module fixtures: b depends on a; main depends on b and c.
local modDir = path.join(tmpBase, "mods")
fs.mkdir(modDir)
fs.write(path.join(modDir, "a.lua"), 'return { tag = "a" }')
fs.write(path.join(modDir, "b.lua"), 'return "b+" .. require("a").tag')
fs.write(path.join(modDir, "c.lua"), 'return { tag = "c" }')
fs.write(path.join(modDir, "d.lua"), 'return { tag = "d" }')
-- Registers an accept callback at load time, so reload tests can assert both
-- that the callback fires and that the module itself hears about its own reload.
fs.write(path.join(modDir, "watcher.lua"), [[
_G.seen = _G.seen or {}
if package.hot then
	package.hot.accept(function(m) _G.seen[#_G.seen + 1] = m end)
end
return "watcher"
]])
fs.write(path.join(modDir, "main.lua"), [[
local b = require("b")
local c = require("c")
return b .. "+" .. c.tag
]])

--- Build a guest state with the bootstrap installed; returns the state and the
--- guest-side reload/reloadAll/checkKey/beginEntry/flushAccepts functions.
---@param mode "hot"|"watch"?
---@return table state, function reload, function reloadAll, function checkKey, function beginEntry, function flushAccepts
local function setup(mode)
	local state, _, cleanup = lde.runtime.createState({
		packagePath = modDir .. "/?.lua;" .. modDir .. "/?/init.lua;",
	})
	local boot = state:load(watchrun.bootstrap, "@lde-watchrun")
	local ok, hotState = boot:pcall({
		abs = function(p) return path.resolve(env.cwd(), p) end,
		-- Stands in for the driver's real watcher poll. What the real one does
		-- (raise the reload marker when a tracked file changed) is covered
		-- end-to-end in packages/lde/tests/hot.test.lua.
		poll = function() return false end,
		mode = mode,
		srcPrefix = nil,
		targetPrefix = nil,
		entryKey = "entry-main",
		exitMarker = "__lde_exit__",
	})
	test.truthy(ok, tostring(hotState)) ---@cast hotState -nil
	return state,
		hotState:get("reload"), --[[@as function]]
		hotState:get("reloadAll"), --[[@as function]]
		hotState:get("checkKey"), --[[@as function]]
		hotState:get("beginEntry"), --[[@as function]]
		hotState:get("flushAccepts") --[[@as function]]
end

test.it("bootstrap tracks modules and their dependency edges", function()
	local state, _, _, checkKey = setup()
	state:eval('local m = require("main"); assert(m == "b+a+c")')

	-- A loaded module's file must be a tracked reload key.
	test.truthy(checkKey(path.join(modDir, "a.lua")))
	test.truthy(checkKey(path.join(modDir, "b.lua")))
	test.truthy(checkKey(path.join(modDir, "main.lua")))
	-- Untracked files are not reload keys.
	test.falsy(checkKey(path.join(modDir, "nope.lua")))
	state:close()
end)

test.it("reload drops a changed module and its transitive dependents", function()
	local state, reload, _, _ = setup()
	state:eval('local m = require("main"); assert(m == "b+a+c")')

	-- a.lua changed: reload(a) must drop a AND b AND main (b requires a,
	-- main requires b), but not c.
	local dropped = reload(path.join(modDir, "a.lua"))
	test.equal(dropped, 3)

	local loaded = state:globals().package.loaded
	test.falsy(loaded:get("a"), "a must be dropped")
	test.falsy(loaded:get("b"), "b must be dropped (dependent of a)")
	test.falsy(loaded:get("main"), "main must be dropped (transitive dependent)")
	test.truthy(loaded:get("c"), "c must survive (unrelated)")
	state:close()
end)

test.it("reload drops only the changed module when it has no dependents", function()
	local state, reload, _, _ = setup()
	state:eval('local m = require("main"); local d = require("d")')

	-- d is required by nobody, so reloading its file drops exactly d.
	local dropped = reload(path.join(modDir, "d.lua"))
	test.equal(dropped, 1)
	test.falsy(state:globals().package.loaded:get("d"))
	test.truthy(state:globals().package.loaded:get("main"), "main must survive")
	state:close()
end)

test.it("reload returns 0 for an untracked key", function()
	local state, reload, _, _ = setup()
	state:eval('local m = require("main")')

	test.equal(reload(path.join(modDir, "nope.lua")), 0)
	state:close()
end)

test.it("reloadAll drops every tracked module", function()
	local state, _, reloadAll, checkKey = setup()
	state:eval('local m = require("main")')

	local dropped = reloadAll()
	test.equal(dropped, 4) -- a, b, c, main (d was never loaded here)

	local loaded = state:globals().package.loaded
	test.falsy(loaded:get("main"))
	test.falsy(loaded:get("b"))
	-- Tracking metadata is cleared too: no file is a reload key anymore.
	test.falsy(checkKey(path.join(modDir, "a.lua")))
	state:close()
end)

test.it("bootstrap wraps os.exit so the driver can intercept it", function()
	local state = setup()
	state:eval('local m = require("main")')

	-- os.exit must raise the exit marker (the driver catches it and keeps
	-- watching) instead of terminating the whole process.
	local ok, err = pcall(state.eval, state, 'os.exit(0)')
	test.falsy(ok)
	test.truthy(tostring(err):find("__lde_exit__", 1, true))
	state:close()
end)

test.it("package.hot exists only in --hot mode", function()
	local hotState = setup("hot")
	test.truthy(hotState:eval("return package.hot ~= nil"))
	test.truthy(hotState:eval("return type(package.hot.accept)"))
	test.truthy(hotState:eval("return type(package.hot.poll)"))
	hotState:close()

	-- --watch recreates the state on every run, so there is nothing to accept
	-- and no live loop to poll from.
	local watchState = setup("watch")
	test.falsy(watchState:eval("return package.hot"))
	watchState:close()
end)

test.it("accept callbacks get the require path of every reloaded module", function()
	local state, reload, _, _, _, flushAccepts = setup("hot")
	state:eval([[
		_G.seen = {}
		local m = require("main")
		package.hot.accept(function(name) _G.seen[#_G.seen + 1] = name end)
	]])

	-- a.lua changed: a, b and main (their dependent) are all dropped.
	test.equal(reload(path.join(modDir, "a.lua")), 3)
	-- Nothing is delivered until the driver says the reload is applied.
	test.equal(state:eval("return #_G.seen"), 0)
	test.equal(flushAccepts(true), 3)
	test.equal(state:eval("return table.concat(_G.seen, ',')"), "a,b,main")
	state:close()
end)

test.it("a module hears about its own reload", function()
	local state, reload, _, _, _, flushAccepts = setup("hot")
	state:eval('local w = require("watcher")')
	test.equal(state:eval("return #_G.seen"), 0, "no callback before the first reload")

	-- The registration is snapshotted before the module is dropped, so the
	-- callback the module made still runs for its own reload.
	test.equal(reload(path.join(modDir, "watcher.lua")), 1)
	test.equal(flushAccepts(true), 1)
	test.equal(state:eval("return table.concat(_G.seen, ',')"), "watcher")
	test.falsy(state:globals().package.loaded:get("watcher"), "watcher must be dropped")

	-- ... and it is gone with the module: no stale callback fires twice.
	test.equal(reload(path.join(modDir, "watcher.lua")), 0)
	test.equal(flushAccepts(true), 0)
	test.equal(state:eval("return #_G.seen"), 1)
	state:close()
end)

test.it("reloadAll notifies every dropped module", function()
	local state, _, reloadAll, _, _, flushAccepts = setup("hot")
	state:eval([[
		_G.seen = {}
		local m = require("main")
		package.hot.accept(function(name) _G.seen[#_G.seen + 1] = name end)
	]])

	test.equal(reloadAll(), 4)
	test.equal(flushAccepts(true), 4)
	test.equal(state:eval("return table.concat(_G.seen, ',')"), "a,b,c,main")
	state:close()
end)

test.it("flushAccepts drops notifications for a reload that was not applied", function()
	local state, reload, _, _, _, flushAccepts = setup("hot")
	state:eval([[
		_G.seen = {}
		require("c")
		require("d")
		package.hot.accept(function(name) _G.seen[#_G.seen + 1] = name end)
	]])

	-- A failed rebuild means the changed sources were never recompiled, so the
	-- queued notification must not leak into the next reload cycle.
	test.equal(reload(path.join(modDir, "d.lua")), 1)
	test.equal(flushAccepts(false), 0)
	test.equal(state:eval("return #_G.seen"), 0)
	test.equal(flushAccepts(true), 0, "the queue must be drained")

	test.equal(reload(path.join(modDir, "c.lua")), 1)
	test.equal(flushAccepts(true), 1)
	test.equal(state:eval("return table.concat(_G.seen, ',')"), "c")
	state:close()
end)

test.it("a module reloaded twice in one cycle is announced once", function()
	local state, reload, _, _, _, flushAccepts = setup("hot")
	state:eval([[
		_G.seen = {}
		local m = require("main")
		package.hot.accept(function(name) _G.seen[#_G.seen + 1] = name end)
	]])

	-- Two saves in one cycle: main is a dependent of both a and c, so it lands
	-- in both batches and must still be reported once.
	reload(path.join(modDir, "a.lua"))
	reload(path.join(modDir, "c.lua"))
	test.equal(flushAccepts(true), 4)
	test.equal(state:eval("return table.concat(_G.seen, ',')"), "a,b,main,c")
	state:close()
end)

test.it("beginEntry replaces the entry point's stale registrations", function()
	local state, reload, _, _, beginEntry, flushAccepts = setup("hot")
	state:eval('local d = require("d")')
	state:eval([[
		_G.seen = {}
		package.hot.accept(function(name) _G.seen[#_G.seen + 1] = name end)
	]])

	-- The entry re-runs after every reload: its new registration must replace
	-- the previous run's closure instead of stacking up beside it.
	beginEntry()
	state:eval('package.hot.accept(function(name) _G.seen[#_G.seen + 1] = name end)')

	test.equal(reload(path.join(modDir, "d.lua")), 1)
	test.equal(flushAccepts(true), 1)
	test.equal(state:eval("return #_G.seen"), 1)
	state:close()
end)

test.it("a failing accept callback does not break the reload", function()
	local state, reload, _, _, _, flushAccepts = setup("hot")
	state:eval([[
		_G.errs = {}
		io.stderr = { write = function(_, ...) _G.errs[#_G.errs + 1] = table.concat({ ... }) end }
		local d = require("d")
		package.hot.accept(function() error("callback boom") end)
	]])

	test.equal(reload(path.join(modDir, "d.lua")), 1)
	test.equal(flushAccepts(true), 1)
	test.truthy(
		state:eval([[return _G.errs[1] ~= nil and _G.errs[1]:find("callback boom", 1, true) ~= nil]]),
		"the callback error must be reported")
	state:close()
end)

test.it("accept rejects a non-function", function()
	local state = setup("hot")

	local ok, err = pcall(state.eval, state, "package.hot.accept('nope')")
	test.falsy(ok)
	test.truthy(tostring(err):find("expects a function", 1, true))
	state:close()
end)

test.it("reload times are reported in the unit that reads best", function()
	-- A patch-only reload lands in the microsecond range, and a sub-millisecond
	-- reload that rounds to "0ms" tells the reader nothing.
	test.equal(watchrun.formatReloadTime(0.000007), "7.0µs")
	test.equal(watchrun.formatReloadTime(0.0001), "100µs")
	test.equal(watchrun.formatReloadTime(0.00042), "420µs")

	-- From a millisecond up (a rebuild fits in here) to seconds.
	test.equal(watchrun.formatReloadTime(0.001), "1.0ms")
	test.equal(watchrun.formatReloadTime(0.00418), "4.2ms")
	test.equal(watchrun.formatReloadTime(0.9999), "999.9ms")
	test.equal(watchrun.formatReloadTime(1.25), "1.25s")
end)
