local test = require("lde-test")
local Archive = require("archive")
local fs = require("fs")
local env = require("env")
local path = require("path")

local tmpBase = path.join(env.tmpdir(), "lde-archive-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

local function tmp(name)
	return path.join(tmpBase, name)
end

--
-- Archive.new
--

test.it("Archive.new with string returns Archive", function()
	local a = Archive.new("/some/path.tar.gz")
	test.truthy(a)
end)

test.it("Archive.new with table returns Archive", function()
	local a = Archive.new({ ["hello.txt"] = "hello" })
	test.truthy(a)
end)

test.it("extract fails when source is a table", function()
	local a = Archive.new({ ["hello.txt"] = "hello" })
	local ok, err = a:extract(tmp("out-table"))
	test.falsy(ok)
	test.truthy(err)
end)

test.it("save fails when source is a string", function()
	local a = Archive.new("/some/path.tar.gz")
	local ok, err = a:save(tmp("out.zip"))
	test.falsy(ok)
	test.truthy(err)
end)

test.it("save fails for unknown extension", function()
	local a = Archive.new({ ["hello.txt"] = "hello" })
	local ok, err = a:save(tmp("out.rar"))
	test.falsy(ok)
	test.truthy(err)
end)

test.it("save encodes to .zip and files are extractable", function()
	local zipPath = tmp("saved.zip")
	local outDir = tmp("out-saved-zip")
	fs.mkdir(outDir)

	local a = Archive.new({ ["hello.txt"] = "zip content" })
	local ok = a:save(zipPath)
	test.truthy(ok)
	test.truthy(fs.exists(zipPath))

	local b = Archive.new(zipPath)
	local ok2 = b:extract(outDir)
	test.truthy(ok2)
	test.equal(fs.read(path.join(outDir, "hello.txt")), "zip content")
end)

test.it("save encodes to .tar.gz and files are extractable", function()
	local tarPath = tmp("saved.tar.gz")
	local outDir = tmp("out-saved-tar")
	fs.mkdir(outDir)

	local a = Archive.new({ ["hello.txt"] = "tar content" })
	local ok = a:save(tarPath)
	test.truthy(ok)
	test.truthy(fs.exists(tarPath))

	local b = Archive.new(tarPath)
	local ok2 = b:extract(outDir)
	test.truthy(ok2)
	test.equal(fs.read(path.join(outDir, "hello.txt")), "tar content")
end)

test.it("extracts a .tar archive", function()
	local tarPath = tmp("test.tar")
	local outDir = tmp("out-tar")
	fs.mkdir(outDir)

	local a = Archive.new({ ["hello.txt"] = "tar content" })
	local ok = a:save(tarPath)
	test.truthy(ok)

	local b = Archive.new(tarPath)
	local ok2 = b:extract(outDir)
	test.truthy(ok2)
	test.truthy(fs.exists(path.join(outDir, "hello.txt")))
end)

test.it("extracts a .zip archive", function()
	local zipPath = tmp("test2.zip")
	local outDir = tmp("out-zip2")
	fs.mkdir(outDir)

	local a = Archive.new({ ["hello.txt"] = "zip content" })
	local ok = a:save(zipPath)
	test.truthy(ok)

	local b = Archive.new(zipPath)
	local ok2 = b:extract(outDir)
	test.truthy(ok2)
	test.truthy(fs.exists(path.join(outDir, "hello.txt")))
end)

test.it("stripComponents strips top-level dir from zip", function()
	local zipPath = tmp("strip.zip")
	local outDir = tmp("out-strip-zip")
	fs.mkdir(outDir)

	local a = Archive.new({ ["topdir/hello.txt"] = "stripped" })
	a:save(zipPath)

	local b = Archive.new(zipPath)
	b:extract(outDir, { stripComponents = true })
	test.equal(fs.read(path.join(outDir, "hello.txt")), "stripped")
end)

-- regression: zips with no explicit directory entries (e.g. .src.rock files)
-- must still extract deeply nested files by creating parent dirs recursively
test.it("extracts zip with deeply nested files and no explicit dir entries", function()
	local zipPath = tmp("nested.zip")
	local outDir  = tmp("out-nested")
	fs.mkdir(outDir)

	-- save creates file entries only, no dir entries — matches .src.rock behavior
	local a = Archive.new({ ["a/b/c/deep.lua"] = "deep content" })
	a:save(zipPath)

	local b = Archive.new(zipPath)
	local ok = b:extract(outDir)
	test.truthy(ok)
	test.equal(fs.read(path.join(outDir, "a/b/c/deep.lua")), "deep content")
end)

test.it("stripComponents strips top-level dir from tar.gz", function()
	local tarPath = tmp("strip.tar.gz")
	local outDir = tmp("out-strip-tar")
	fs.mkdir(outDir)

	local a = Archive.new({ ["topdir/hello.txt"] = "stripped" })
	a:save(tarPath)

	local b = Archive.new(tarPath)
	b:extract(outDir, { stripComponents = true })
	test.equal(fs.read(path.join(outDir, "hello.txt")), "stripped")
end)
