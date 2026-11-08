const test = require("lde-test")
const browser = require("lde.util.browser")

---@param codes table<string, integer>
---@return function
---@return table[]
local function fakeSpawn(codes)
	local calls = {}
	return function(name, args, opts)
		calls[#calls + 1] = { name = name, args = args, opts = opts }
		return {
			wait = function()
				return codes[name] or 1
			end,
		}
	end, calls
end

test.it("opens a URL with xdg-open on Linux", function()
	const spawn, calls = fakeSpawn({ ["xdg-open"] = 0 })
	test.truthy(browser.open("https://github.com/login/device", { os = "Linux", spawn = spawn }))
	test.equal(calls[1].name, "xdg-open")
	test.equal(calls[1].args[1], "https://github.com/login/device")
	test.equal(calls[1].opts.stdout, "null")
	test.equal(calls[1].opts.stderr, "null")
end)

test.it("falls back when the first opener is missing or fails", function()
	const spawn, calls = fakeSpawn({ ["gio"] = 0 })
	test.truthy(browser.open("https://github.com/login/device", { os = "Linux", spawn = spawn }))
	test.equal(calls[1].name, "xdg-open")
	test.equal(calls[2].name, "gio")
	test.equal(calls[2].args[1], "open")
	test.equal(calls[2].args[2], "https://github.com/login/device")
end)

test.it("uses open on macOS", function()
	const spawn, calls = fakeSpawn({ open = 0 })
	test.truthy(browser.open("https://github.com/login/device", { os = "OSX", spawn = spawn }))
	test.equal(calls[1].name, "open")
	test.equal(calls[1].args[1], "https://github.com/login/device")
end)

test.it("uses start on Windows", function()
	const spawn, calls = fakeSpawn({ cmd = 0 })
	test.truthy(browser.open("https://github.com/login/device", { os = "Windows", spawn = spawn }))
	test.equal(calls[1].name, "cmd")
	test.equal(calls[1].args[1], "/c")
	test.equal(calls[1].args[2], "start")
	test.equal(calls[1].args[4], "https://github.com/login/device")
end)

test.it("returns false when no opener works", function()
	const spawn = fakeSpawn({})
	test.falsy(browser.open("https://github.com/login/device", { os = "Linux", spawn = spawn }))
end)
