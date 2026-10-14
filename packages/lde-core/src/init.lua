local lde = {}

package.loaded[(...)] = lde

lde.isVerbose = false
-- `lde ... --json` pipes a report to stdout; progress output must not mix in.
lde.isQuiet = false

-- `error` is eager (crash boundary); eager-requiring the rest pulled the whole graph on every start (~1.5ms).
lde.error = require("lde-core.error")

-- Never executed: gives the language server real types for the lazy fields below.
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

---@type table<string, string>
const lazyModules = {
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
		const name = lazyModules[k]
		if not name then return nil end
		const m = require(name)
		rawset(t, k, m)
		return m
	end,
})

return lde
