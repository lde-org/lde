local lde = {}

package.loaded[(...)] = lde

lde.isVerbose = false

lde.error = require("lde-core.error")

lde.Registry = require("lde-registry")

lde.Package = require("lde-core.package")
lde.Lockfile = require("lde-core.lockfile")

lde.global = require("lde-core.global")
lde.runtime = require("lde-core.runtime")
lde.flamegraph = require("lde-core.flamegraph")
lde.watchrun = require("lde-core.watchrun")

lde.util = require("lde-core.util")

return lde
