local test = require("lpm-test")

local fs = require("fs")
local env = require("env")
local path = require("path")

local tmpBase = path.join(env.tmpdir(), "lpm-fs-tests")

fs.rmdir(tmpBase)

--
-- fs.scan
--

test.it("fs.scan does not follow directory symlinks", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "scan-symlink")
	local subdir = path.join(dir, "sub")
	fs.mkdir(dir)
	fs.mkdir(subdir)
	fs.write(path.join(subdir, "file.lua"), "return true")

	-- Create a symlink inside the dir that points back to the parent dir.
	-- Without the fix this causes fs.scan to recurse infinitely.
	local linked = path.join(dir, "loop")
	fs.mklink(dir, linked)

	local results = fs.scan(dir, "**.lua")

	-- Should find file.lua exactly once, without looping
	test.equal(#results, 1)
	test.includes(results[1], "file.lua")
end)

test.it("fs.scan finds files recursively without symlinks", function()
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, "scan-basic")
	local a = path.join(dir, "a")
	local b = path.join(dir, "b", "c")
	fs.mkdir(dir)
	fs.mkdir(a)
	fs.mkdir(path.join(dir, "b"))
	fs.mkdir(b)
	fs.write(path.join(a, "one.lua"), "")
	fs.write(path.join(b, "two.lua"), "")
	fs.write(path.join(dir, "three.lua"), "")

	local results = fs.scan(dir, "**.lua")
	table.sort(results)

	test.equal(#results, 3)
end)
