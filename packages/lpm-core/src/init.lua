local lpm = {}

lpm.Package = require("lpm-core.package")
lpm.Lockfile = require("lpm-core.lockfile")
lpm.Config = require("lpm-core.config")

lpm.global = require("lpm-core.global")
lpm.runtime = require("lpm-core.runtime")

return lpm
