local test = require("lpm-test")
local rocked = require("rocked")
local http = require("http")

test.it("should be able to parse busted's rockspec", function()
	local spec, err = http.get(
		"https://raw.githubusercontent.com/lunarmodules/busted/56e6d68204d1456afa77f1346bf4e050df65b629/rockspecs/busted-2.3.0-1.rockspec"
	)

	if not spec then
		error("Failed to GET busted rockspec: " .. err)
	end

	local ok, parsed = rocked.parse(spec)
	if not ok then
		error("Failed to parse rockspec: " .. parsed)
	end
end)

test.it("should be in a separate environment", function()
	local spec = [[
		print('i shouldnt be able to print')
	]]

	local ok, parsed = rocked.parse(spec)
	if ok then
		error("Expected rockspec to fail, but it succeeded")
	end ---@cast parsed string

	test.notEqual(parsed:find("attempt to call global 'print'"), nil)
end)

test.it("shouldn't run for too long", function()
	local spec = [[
		while true do end
	]]

	local ok, parsed = rocked.parse(spec)
	if ok then
		error("Expected rockspec to fail, but it succeeded")
	end ---@cast parsed string

	test.notEqual(parsed:find("Rockspec took too long to run"), nil)
end)
