const test = require("lde-test")

const lde = require("lde-core")

const fs = require("fs")
const env = require("env")
const path = require("path")

local tmpDir = path.join(env.tmpdir(), "lde-json5config-test")
fs.rmdir(tmpDir)
fs.mkdir(tmpDir)

const json5Config = [[
{
	// Project hasMetadata
	"name": "json5-sample",
	"version": "1.0.0", // trailing comma below
	/* multi-line comment:
	   describes the dependencies */
	"dependencies": {
		foo: { "path": "../foo" }, // identifier key, trailing comma
		"bar": { 'path': '../bar' }, // single-quoted value
	},
}
]]

fs.write(path.join(tmpDir, "lde.json"), json5Config)

test.it("Package.open succeeds for a project with a JSON5 lde.json", function()
	local pkg, err = lde.Package.open(tmpDir)
	test.truthy(pkg)
	test.falsy(err)
end)

test.it("Package:readConfig parses name from JSON5 lde.json", function()
	local pkg = assert(lde.Package.open(tmpDir))
	local config = pkg:readConfig()
	test.equal(config.name, "json5-sample")
	test.equal(config.version, "1.0.0")
end)

test.it("Package:readConfig parses dependencies from JSON5 lde.json", function()
	local pkg = assert(lde.Package.open(tmpDir))
	local config = pkg:readConfig()
	test.equal(config.dependencies.foo.path, "../foo")
	test.equal(config.dependencies.bar.path, "../bar")
end)
