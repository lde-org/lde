local test = require("lde-test")

local lde = require("lde-core")

test.it("Config.new wraps a table with the Config metatable", function()
	local conf = lde.Config.new({
		name = "my-package",
		version = "1.0.0"
	})

	test.equal(conf.name, "my-package")
	test.equal(conf.version, "1.0.0")
end)

test.it("Config preserves dependencies", function()
	local conf = lde.Config.new({
		name = "test-pkg",
		version = "0.1.0",
		dependencies = {
			foo = { path = "../foo" }
		}
	})

	test.match(conf.dependencies, { foo = { path = "../foo" } })
end)

test.it("Config preserves git dependencies", function()
	local conf = lde.Config.new({
		name = "test-pkg",
		version = "0.2.0",
		dependencies = {
			bar = { git = "https://example.com/bar.git", branch = "main" }
		}
	})

	test.match(conf.dependencies, { bar = { git = "https://example.com/bar.git", branch = "main" } })
end)

test.it("Config with no dependencies returns nil for dependencies field", function()
	local conf = lde.Config.new({
		name = "empty",
		version = "0.0.1"
	})

	test.falsy(conf.dependencies)
end)

test.it("Config preserves devDependencies", function()
	local conf = lde.Config.new({
		name = "test-pkg",
		version = "0.1.0",
		devDependencies = {
			testlib = { path = "../testlib" }
		}
	})

	test.match(conf.devDependencies, { testlib = { path = "../testlib" } })
end)

test.it("Config preserves engine field", function()
	local conf = lde.Config.new({
		name = "test-pkg",
		version = "0.1.0",
		engine = "luajit"
	})

	test.equal(conf.engine, "luajit")
end)
