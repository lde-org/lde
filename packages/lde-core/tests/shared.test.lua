const test = require("lde-test")

const lde = require("lde-core")
const fs = require("fs")
const env = require("env")
local path = require("path")
const json = require("json")
const ffi = require("ffi")
const process = require("process")

local tmpBase = path.join(env.tmpdir(), "lde-shared-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

---@param name string
---@param files table<string, string> # src-relative path -> content
local function makePackage(name, files)
	local dir = path.join(tmpBase, name)
	fs.mkdirAll(path.join(dir, "src"))
	for rel, content in pairs(files) do
		fs.write(path.join(dir, "src", rel), content)
	end
	fs.write(path.join(dir, "lde.json"), json.encode({ name = name, version = "0.1.0", dependencies = {} }))
	return assert(lde.Package.open(dir))
end

---@param pkg lde.Package
local function compileShared(pkg)
	const ext = jit.os == "Windows" and ".dll" or jit.os == "OSX" and ".dylib" or ".so"
	const libPath = path.join(pkg:getDir(), pkg:getName() .. ext)
	fs.move(pkg:compile(nil, { shared = true }), libPath)
	return libPath
end

test.it("compile --shared: exports are callable through the C ABI and the entry point runs once, on first use", function()
	const marker = path.join(tmpBase, "shared-app-inits")
	const pkg = makePackage("shared-app", {
		["init.lua"] = [[
local inits = 0
require("shared-app.strings")

---@export "C" sharedtest_add fn(a: u32, b: u32): u32
local function add(a, b) return a + b end

---@export "C" sharedtest_inits fn(): i32
local function getInits() return inits end

---@export "C" sharedtest_u64 fn(x: u64): u64
local function u64(x) return x end

inits = inits + 1
local f = assert(io.open(]] .. string.format("%q", marker) .. [[, "a"))
f:write("x")
f:close()
]],
		["strings.lua"] = [[
---@export "C" sharedtest_greet fn(name: string): string
local function greet(name) return "hello " .. name end
return {}
]],
	})

	const lib = ffi.load(compileShared(pkg))
	ffi.cdef([[
		uint32_t sharedtest_add(uint32_t a, uint32_t b);
		int32_t sharedtest_inits(void);
		uint64_t sharedtest_u64(uint64_t x);
		const char* sharedtest_greet(const char* name);
	]])
	test.falsy(fs.exists(marker), "loading the library must not run the entry point")

	test.equal(lib.sharedtest_add(4294967295, 2), 1, "u32 arithmetic wraps at the C boundary")
	test.equal(lib.sharedtest_inits(), 1, "the entry point runs exactly once")
	test.equal(ffi.string(lib.sharedtest_greet("world")), "hello world", "exports in required modules register too")
	test.truthy(lib.sharedtest_u64(18446744073709551557ULL) == 18446744073709551557ULL,
		"u64 values beyond 2^53 cross both ways exactly")
	test.equal(lib.sharedtest_add(2, 3), 5)
	test.equal(fs.read(marker), "x")
end)

test.it("compile --shared: a Lua error in an export panics the process with its traceback", function()
	const libPath = compileShared(makePackage("shared-panic", {
		["init.lua"] = [[
---@export "C" paniclib_fail fn(): i32
local function fail() error("intentional failure") end
]],
	}))
	const script = path.join(tmpBase, "shared-panic-host.lua")
	fs.write(script, [[
local ffi = require("ffi")
ffi.cdef("int32_t paniclib_fail(void);")
ffi.load(...).paniclib_fail()
print("returned")
]])

	-- Run in a child: the panic aborts whichever process loaded the library.
	const code, stdout, stderr = process.exec(assert(env.execPath()), { "--lua", script, libPath })
	test.truthy(code ~= 0, "a panicking export must not return")
	test.falsy((stdout or ""):find("returned", 1, true), "the caller must never see a return value")
	test.includes(stderr or "", "lde: panic in exported function 'paniclib_fail'")
	test.includes(stderr or "", "intentional failure")
	test.includes(stderr or "", "stack traceback:")
end)

test.it("compile --shared: an export re-entered from Lua through the FFI sees its own frame", function()
	const pkg = makePackage("shared-reenter", {
		["init.lua"] = [[
local ffi = require("ffi")

---@export "C" reenter_inner fn(x: i32): i32
local function inner(x) return x * 10 end

---@export "C" reenter_outer fn(cb: ptr, x: i32): i32
local function outer(cb, x)
	local offset = 7
	return ffi.cast("int32_t(*)(int32_t)", cb)(x) + offset
end
]],
	})

	const lib = ffi.load(compileShared(pkg))
	ffi.cdef([[
		int32_t reenter_inner(int32_t x);
		int32_t reenter_outer(void* cb, int32_t x);
	]])
	-- reenter_outer's Lua code calls reenter_inner's C glue while its own frame is live.
	test.equal(lib.reenter_outer(ffi.cast("void*", lib.reenter_inner), 4), 47)
	test.equal(lib.reenter_inner(5), 50, "the fast path still works after a re-entrant call")
end)

test.it("compile --shared: exports in Teal sources are found even though tl drops comments", function()
	const pkg = makePackage("shared-teal", {
		["init.tl"] = [[
local record Pair
	a: integer
	b: integer
end

-- tl turns every comment line into a blank line.
---@export "C" tealtest_add fn(a: i32, b: i32): i32
local function add(a: integer, b: integer): integer
	local pair: Pair = { a = a, b = b }
	return pair.a + pair.b
end
]],
	})

	const lib = ffi.load(compileShared(pkg))
	ffi.cdef("int32_t tealtest_add(int32_t a, int32_t b);")
	test.equal(lib.tealtest_add(40, 2), 42)
end)

test.it("compile --shared: a package without ---@export annotations fails cleanly", function()
	const pkg = makePackage("shared-none", { ["init.lua"] = "return {}" })
	const ok, err = pcall(compileShared, pkg)
	test.falsy(ok)
	test.includes(tostring(err), "no `---@export")
end)
