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
fs.write(path.join(modDir, "main.lua"), [[
local b = require("b")
local c = require("c")
return b .. "+" .. c.tag
]])

--- Build a guest state with the bootstrap installed; returns the state and the
--- guest-side reload/reloadAll/checkKey functions.
---@return table state, function reload, function reloadAll, function checkKey
local function setup()
	local state, _, cleanup = lde.runtime.createState({
		packagePath = modDir .. "/?.lua;" .. modDir .. "/?/init.lua;",
	})
	local boot = state:load(watchrun.bootstrap, "@lde-watchrun")
	local ok, hotState = boot:pcall({
		abs = function(p) return path.resolve(env.cwd(), p) end,
		srcPrefix = nil,
		targetPrefix = nil,
		entryKey = "entry-main",
		exitMarker = "__lde_exit__",
	})
	test.truthy(ok, tostring(hotState)) ---@cast hotState -nil
	return state,
		hotState:get("reload"), --[[@as function]]
		hotState:get("reloadAll"), --[[@as function]]
		hotState:get("checkKey") --[[@as function]]
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
