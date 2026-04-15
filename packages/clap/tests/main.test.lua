local test = require("lde-test")

local clap = require("clap")

test.it("option does not consume -- as a value", function()
	local args = clap.parse({ "--profile", "--flamegraph", "--", "--cwd", "../..", "test" })

	test.truthy(args:flag("profile"))
	test.equal(args:option("flamegraph"), nil)
	test.equal(args:peek(), "--flamegraph")

	local dash, dashPos = args:flag("")
	test.truthy(dash)
	test.equal(dashPos, 1)

	local rest = args:drain(dashPos)
	test.equal(rest[1], "--flamegraph")
	test.equal(rest[2], "--cwd")
	test.equal(rest[3], "../..")
	test.equal(rest[4], "test")
end)
