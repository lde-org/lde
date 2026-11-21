const test = require("lde-test")

const exportScanner = require("lde-core.package.exports")

test.it("exports: registration lands after the function's own end, past nested blocks, strings and comments", function()
	const src = table.concat({
		'---@export "C" demo_add fn(a: uint32_t, b: u32): u32',
		"local function add(a, b)",
		"\tif a > 1 then for i = 1, 2 do end elseif b then repeat until true end",
		"\tlocal s = \"end\" .. 'end' .. [==[ end ]] end ]==] -- end",
		"\t--[[ end",
		"\tend ]]",
		"\treturn a + b",
		"end",
		"return add",
	}, "\n")

	const out, found, err = exportScanner.process(src, "init.lua")
	test.truthy(out, err) ---@cast out string
	test.truthy(found) ---@cast found sea.Export[]
	test.equal(#found, 1)
	test.equal(found[1].name, "demo_add")
	test.equal(table.concat(found[1].params, ","), "u32,u32", "stdint spellings resolve to the canonical names")
	test.equal(found[1].ret, "u32")

	const lines = {}
	for line in (out .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
	test.equal(#lines, 9, "the rewrite must not shift line numbers")
	test.equal(lines[8], 'end debug.getregistry()["lde.exports"]["demo_add"] = add')
end)

test.it("exports: the symbol name defaults to the local function's name and the return type to void", function()
	const _, found = exportScanner.process('---@export "C" fn(p: ptr)\nlocal function poke(p) end', "init.lua")
	test.truthy(found) ---@cast found sea.Export[]
	test.equal(found[1].name, "poke")
	test.equal(found[1].ret, "void")
	test.equal(found[1].params[1], "ptr")
end)

test.it("exports: fun(...) and function(...) are accepted as spellings of fn(...)", function()
	for _, keyword in ipairs({ "fun", "function" }) do
		const src = '---@export "C" f ' .. keyword .. "(a: i32): i32\nlocal function f(a) return a end"
		const _, found, err = exportScanner.process(src, "init.lua")
		test.truthy(found, err) ---@cast found sea.Export[]
		test.equal(found[1].name, "f", keyword)
		test.equal(found[1].ret, "i32", keyword)
	end
end)

test.it("exports: a symbol may itself be called fn", function()
	const _, found = exportScanner.process('---@export "C" fn fn(): i32\nlocal function f() return 1 end', "init.lua")
	test.truthy(found) ---@cast found sea.Export[]
	test.equal(found[1].name, "fn")
end)

test.it("exports: types outside the allowed set are rejected with their line", function()
	const out, _, err = exportScanner.process('\n---@export "C" f fn(a: int): i32\nlocal function f(a) end', "init.lua")
	test.falsy(out)
	test.equal(err, "init.lua:2: unsupported type 'int' for parameter 'a'")
end)

test.it("exports: a parameter count that differs from the Lua function is rejected", function()
	const out, _, err = exportScanner.process('---@export "C" f fn(a: i32): i32\nlocal function f(a, b) end', "init.lua")
	test.falsy(out)
	test.includes(tostring(err), "takes 2 parameters but its ---@export declares 1")
end)

test.it("exports: an annotation not directly above a local function is rejected", function()
	const out, _, err = exportScanner.process('---@export "C" f fn(): i32\nfunction f() end', "init.lua")
	test.falsy(out)
	test.includes(tostring(err), "must be directly followed by a `local function name(...)`")
end)
