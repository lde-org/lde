local lde = {}

package.loaded[(...)] = lde

lde.verbose = false

lde.Package = require("lde-core.package")
lde.Lockfile = require("lde-core.lockfile")

lde.global = require("lde-core.global")
lde.runtime = require("lde-core.runtime")
lde.flamegraph = require("lde-core.flamegraph")

lde.util = require("lde-core.util")

return lde
