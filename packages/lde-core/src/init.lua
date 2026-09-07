local lde = {}

package.loaded[(...)] = lde

lde.isVerbose = false
-- Suppresses even the compact install progress line (e.g. `lde bloat --json`
-- pipes a report to stdout and must not have progress output mixed in).
lde.isQuiet = false

-- `error` stays eager: the crash boundary and every raise path use it, and it
-- pulls no other module in. Everything else below loads on first access —
-- an eager require here pulled the whole graph (registry, package, global,
-- runtime, …) on every invocation, which dominated CLI startup (~1.5ms).
lde.error = require("lde-core.error")

-- Type scaffolding for the lazily-loaded fields below: assigning each field
-- here (never executed — the compiler folds `if false` away) keeps the full
-- module types visible to the language server, instead of degrading to `any`
-- behind the __index hook. Types stay derived from the modules themselves,
-- so they can't drift from the real shapes.
if false then
	lde.timings = require("lde-core.util.timings")
	lde.Registry = require("lde-registry")
	lde.Package = require("lde-core.package")
	lde.Lockfile = require("lde-core.lockfile")
	lde.global = require("lde-core.global")
	lde.runtime = require("lde-core.runtime")
	lde.flamegraph = require("lde-core.flamegraph")
	lde.watchrun = require("lde-core.watchrun")
	lde.util = require("lde-core.util")
end

-- Lazily-loaded submodules, keyed by the lde field name. The __index hook
-- resolves each field once (then caches it via rawset), so call sites like
-- `lde.global.getDir()` behave exactly as before — the module just loads on
-- first use instead of at lde-core load time.
---@type table<string, string>
local lazyModules = {
	timings    = "lde-core.util.timings",
	Registry   = "lde-registry",
	Package    = "lde-core.package",
	Lockfile   = "lde-core.lockfile",
	global     = "lde-core.global",
	runtime    = "lde-core.runtime",
	flamegraph = "lde-core.flamegraph",
	watchrun   = "lde-core.watchrun",
	util       = "lde-core.util",
}

setmetatable(lde, {
	__index = function(t, k)
		local name = lazyModules[k]
		if not name then return nil end
		local m = require(name)
		rawset(t, k, m)
		return m
	end,
})

return lde
