local test = require("lde-test")
local fs = require("fs")
local env = require("env")
local path = require("path")

local tmpBase = path.join(env.tmpdir(), "lde-fs-pkg-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

-- helpers
local function tmp(name)
	return path.join(tmpBase, name)
end

--
-- exists / isfile / isdir
--

test.it("exists returns false for missing path", function()
	test.falsy(fs.exists(tmp("no-such-file")))
end)

test.it("write creates a file and exists returns true", function()
	local p = tmp("hello.txt")
	test.truthy(fs.write(p, "hello"))
	test.truthy(fs.exists(p))
	test.truthy(fs.isfile(p))
	test.falsy(fs.isdir(p))
end)

test.it("read returns written content", function()
	local p = tmp("read-test.txt")
	fs.write(p, "content123")
	test.equal(fs.read(p), "content123")
end)

test.it("read returns nil for missing file", function()
	test.falsy(fs.read(tmp("missing.txt")))
end)

--
-- mkdir / isdir
--

test.it("mkdir creates a directory", function()
	local d = tmp("mydir")
	test.truthy(fs.mkdir(d))
	test.truthy(fs.isdir(d))
	test.falsy(fs.isfile(d))
end)

--
-- stat
--

test.it("stat returns size and modifyTime for a file", function()
	local p = tmp("stat-test.txt")
	fs.write(p, "abcde")
	local s = fs.stat(p)
	test.truthy(s)
	test.equal(s.size, 5)
	test.truthy(s.modifyTime)
	test.equal(s.type, "file")
end)

test.it("stat returns type=dir for a directory", function()
	local d = tmp("stat-dir")
	fs.mkdir(d)
	local s = fs.stat(d)
	test.truthy(s)
	test.equal(s.type, "dir")
end)

test.it("stat returns nil for missing path", function()
	test.falsy(fs.stat(tmp("nope")))
end)

--
-- delete
--

test.it("delete removes a file", function()
	local p = tmp("del-me.txt")
	fs.write(p, "bye")
	test.truthy(fs.delete(p))
	test.falsy(fs.exists(p))
end)

--
-- rmdir
--

test.it("rmdir removes a directory recursively", function()
	local d = tmp("rmdir-test")
	fs.mkdir(d)
	fs.write(path.join(d, "a.txt"), "a")
	fs.mkdir(path.join(d, "sub"))
	fs.write(path.join(d, "sub", "b.txt"), "b")
	test.truthy(fs.rmdir(d))
	test.falsy(fs.exists(d))
end)

--
-- copy
--

test.it("copy copies a file", function()
	local src = tmp("copy-src.txt")
	local dst = tmp("copy-dst.txt")
	fs.write(src, "copied!")
	test.truthy(fs.copy(src, dst))
	test.equal(fs.read(dst), "copied!")
end)

test.it("copy copies a directory recursively", function()
	local src = tmp("copy-dir-src")
	local dst = tmp("copy-dir-dst")
	fs.mkdir(src)
	fs.write(path.join(src, "f.txt"), "hi")
	fs.mkdir(path.join(src, "sub"))
	fs.write(path.join(src, "sub", "g.txt"), "there")
	test.truthy(fs.copy(src, dst))
	test.equal(fs.read(path.join(dst, "f.txt")), "hi")
	test.equal(fs.read(path.join(dst, "sub", "g.txt")), "there")
end)

--
-- move
--

test.it("move renames a file", function()
	local src = tmp("move-src.txt")
	local dst = tmp("move-dst.txt")
	fs.write(src, "moved")
	test.truthy(fs.move(src, dst))
	test.falsy(fs.exists(src))
	test.equal(fs.read(dst), "moved")
end)

test.it("move removes source directory after moving", function()
	local src = tmp("move-dir-src")
	local dst = tmp("move-dir-dst")
	fs.mkdir(src)
	fs.write(path.join(src, "file.txt"), "content")
	test.truthy(fs.move(src, dst))
	test.falsy(fs.exists(src))
	test.equal(fs.read(path.join(dst, "file.txt")), "content")
end)

--
-- readdir
--

test.it("readdir iterates directory entries", function()
	local d = tmp("readdir-test")
	fs.mkdir(d)
	fs.write(path.join(d, "one.txt"), "")
	fs.write(path.join(d, "two.txt"), "")

	local names = {}
	for entry in fs.readdir(d) do
		names[#names + 1] = entry.name
	end
	table.sort(names)
	test.equal(#names, 2)
	test.equal(names[1], "one.txt")
	test.equal(names[2], "two.txt")
end)

test.it("readdir returns nil for missing directory", function()
	test.falsy(fs.readdir(tmp("no-dir")))
end)

--
-- symlinks
--

test.it("mklink creates a symlink and islink detects it", function()
	local target = tmp("link-target.txt")
	local link   = tmp("link-itself")
	fs.write(target, "target")
	test.truthy(fs.mklink(target, link))
	-- On Windows, file symlinks fall back to hard links when Developer Mode is
	-- disabled. Hard links are not reparse points, so islink returns false.
	if jit.os ~= "Windows" then
		test.truthy(fs.islink(link))
	else
		test.truthy(fs.exists(link))
	end
end)

test.it("rmlink removes a symlink", function()
	local target = tmp("rmlink-target.txt")
	local link   = tmp("rmlink-link")
	fs.write(target, "t")
	fs.mklink(target, link)
	test.truthy(fs.rmlink(link))
	test.falsy(fs.exists(link))
end)

--
-- scan
--

test.it("scan finds files matching glob", function()
	local d = tmp("scan-test")
	fs.mkdir(d)
	fs.mkdir(path.join(d, "sub"))
	fs.write(path.join(d, "a.lua"), "")
	fs.write(path.join(d, "b.txt"), "")
	fs.write(path.join(d, "sub", "c.lua"), "")

	local results = fs.scan(d, "**.lua")
	test.equal(#results, 2)
end)

--
-- watch
--

test.it("watch returns a watcher for an existing directory", function()
	local d = tmp("watch-test")
	fs.mkdir(d)
	local w = fs.watch(d, function() end)
	test.truthy(w)
	w.close()
end)

test.it("watch detects file creation via poll", function()
	local d = tmp("watch-create")
	fs.mkdir(d)

	local events = {}
	local w = fs.watch(d, function(event, name)
		events[#events + 1] = { event = event, name = name }
	end)
	test.truthy(w)

	fs.write(path.join(d, "new.txt"), "hello")

	-- Give the OS a moment to register the event, then poll
	local deadline = os.clock() + 1
	while #events == 0 and os.clock() < deadline do
		w.poll()
	end

	w.close()
	test.truthy(#events > 0)
	test.equal(events[1].event, "create")
end)

test.it("watch detects file modification via poll", function()
	local d = tmp("watch-modify")
	fs.mkdir(d)
	local p = path.join(d, "mod.txt")
	fs.write(p, "v1")

	local events = {}
	local w = fs.watch(d, function(event, name)
		events[#events + 1] = { event = event, name = name }
	end)
	test.truthy(w)

	fs.write(p, "v2")

	local deadline = os.clock() + 1
	while #events == 0 and os.clock() < deadline do
		w.poll()
	end

	w.close()
	test.truthy(#events > 0)
end)

test.it("watch detects file deletion via poll", function()
	local d = tmp("watch-delete")
	fs.mkdir(d)
	local p = path.join(d, "gone.txt")
	fs.write(p, "bye")

	local events = {}
	local w = fs.watch(d, function(event, name)
		events[#events + 1] = { event = event, name = name }
	end)
	test.truthy(w)

	fs.delete(p)

	local deadline = os.clock() + 1
	while #events == 0 and os.clock() < deadline do
		w.poll()
	end

	w.close()
	test.truthy(#events > 0)
	test.equal(events[1].event, "delete")
end)

test.it("wait blocks until file creation", function()
	local d = tmp("wait-create")
	fs.mkdir(d)

	local events = {}
	local w = fs.watch(d, function(event, name)
		events[#events + 1] = { event = event, name = name }
	end)
	test.truthy(w)

	-- Write in a coroutine so wait() can block the main thread
	local co = coroutine.create(function()
		fs.write(path.join(d, "new.txt"), "hello")
	end)

	-- Issue the write before wait() so the event is queued
	coroutine.resume(co)
	w.wait()

	w.close()
	test.truthy(#events > 0)
	test.equal(events[1].event, "create")
end)

test.it("wait blocks until file modification", function()
	local d = tmp("wait-modify")
	fs.mkdir(d)
	local p = path.join(d, "mod.txt")
	fs.write(p, "v1")

	local events = {}
	local w = fs.watch(d, function(event, name)
		events[#events + 1] = { event = event, name = name }
	end)
	test.truthy(w)

	fs.write(p, "v2")
	w.wait()

	w.close()
	test.truthy(#events > 0)
end)

test.it("wait blocks until file deletion", function()
	local d = tmp("wait-delete")
	fs.mkdir(d)
	local p = path.join(d, "gone.txt")
	fs.write(p, "bye")

	local events = {}
	local w = fs.watch(d, function(event, name)
		events[#events + 1] = { event = event, name = name }
	end)
	test.truthy(w)

	fs.delete(p)
	w.wait()

	w.close()
	test.truthy(#events > 0)
	test.equal(events[1].event, "delete")
end)

--
-- watch recursive
--

test.it("watch recursive detects file creation in subdirectory via poll", function()
	local d = tmp("watch-rec-create")
	local sub = path.join(d, "sub")
	fs.mkdir(d)
	fs.mkdir(sub)

	local events = {}
	local w = fs.watch(d, function(event, name)
		events[#events + 1] = { event = event, name = name }
	end, { recursive = true })
	test.truthy(w)

	fs.write(path.join(sub, "deep.txt"), "hello")

	local deadline = os.clock() + 1
	while #events == 0 and os.clock() < deadline do
		w.poll()
	end

	w.close()
	test.truthy(#events > 0)
	test.equal(events[1].event, "create")
end)

test.it("watch recursive detects file modification in subdirectory via poll", function()
	local d = tmp("watch-rec-modify")
	local sub = path.join(d, "sub")
	fs.mkdir(d)
	fs.mkdir(sub)
	local p = path.join(sub, "mod.txt")
	fs.write(p, "v1")

	local events = {}
	local w = fs.watch(d, function(event, name)
		events[#events + 1] = { event = event, name = name }
	end, { recursive = true })
	test.truthy(w)

	fs.write(p, "v2")

	local deadline = os.clock() + 1
	while #events == 0 and os.clock() < deadline do
		w.poll()
	end

	w.close()
	test.truthy(#events > 0)
end)

test.it("watch recursive detects creation in newly created subdirectory", function()
	local d = tmp("watch-rec-newdir")
	fs.mkdir(d)

	local events = {}
	local w = fs.watch(d, function(event, name)
		events[#events + 1] = { event = event, name = name }
	end, { recursive = true })
	test.truthy(w)

	local sub = path.join(d, "newdir")
	fs.mkdir(sub)

	-- Block on the mkdir event so the watcher can register the new subdir
	w.wait()

	local before = #events
	fs.write(path.join(sub, "file.txt"), "hi")

	local deadline = os.clock() + 1
	while #events == before and os.clock() < deadline do
		w.poll()
	end

	w.close()
	test.truthy(#events > before)
end)


--
-- rmdir edge cases
--

test.it("rmdir returns false for non-existent directory", function()
	test.falsy(fs.rmdir(tmp("rmdir-missing")))
end)

test.it("rmdir removes an empty directory", function()
	local d = tmp("rmdir-empty")
	fs.mkdir(d)
	test.truthy(fs.rmdir(d))
	test.falsy(fs.exists(d))
end)

test.it("rmdir removes deeply nested directories", function()
	local d = tmp("rmdir-deep")
	local deep = path.join(d, "a", "b", "c")
	-- mkdir only creates one level, so build manually
	fs.mkdir(d)
	fs.mkdir(path.join(d, "a"))
	fs.mkdir(path.join(d, "a", "b"))
	fs.mkdir(deep)
	fs.write(path.join(deep, "leaf.txt"), "x")
	test.truthy(fs.rmdir(d))
	test.falsy(fs.exists(d))
end)

test.it("rmdir on a symlink to a directory removes only the link", function()
	local target = tmp("rmdir-link-target")
	local link   = tmp("rmdir-link-itself")
	fs.mkdir(target)
	fs.mklink(target, link)
	test.truthy(fs.rmdir(link))
	test.falsy(fs.exists(link))
	test.truthy(fs.exists(target)) -- target must survive
	fs.rmdir(target)
end)

--
-- delete edge cases
--

test.it("delete returns false for non-existent file", function()
	test.falsy(fs.delete(tmp("delete-missing.txt")))
end)

--
-- mkdir edge cases
--

test.it("mkdir is idempotent on an existing directory", function()
	local d = tmp("mkdir-idempotent")
	fs.mkdir(d)
	-- second call should not error and directory still exists
	fs.mkdir(d)
	test.truthy(fs.isdir(d))
end)

--
-- write / read edge cases
--

test.it("write overwrites existing file content", function()
	local p = tmp("overwrite.txt")
	fs.write(p, "first")
	fs.write(p, "second")
	test.equal(fs.read(p), "second")
end)

test.it("write handles empty string content", function()
	local p = tmp("empty-write.txt")
	test.truthy(fs.write(p, ""))
	test.equal(fs.read(p), "")
end)

test.it("write handles binary / multi-line content", function()
	local p = tmp("binary.txt")
	local content = "line1\nline2\nline3"
	fs.write(p, content)
	test.equal(fs.read(p), content)
end)

--
-- copy edge cases
--

test.it("copy returns false for missing source", function()
	test.falsy(fs.copy(tmp("copy-no-src.txt"), tmp("copy-no-dst.txt")))
end)

test.it("copy overwrites an existing destination file", function()
	local src = tmp("copy-over-src.txt")
	local dst = tmp("copy-over-dst.txt")
	fs.write(src, "new")
	fs.write(dst, "old")
	test.truthy(fs.copy(src, dst))
	test.equal(fs.read(dst), "new")
end)

--
-- move edge cases
--

test.it("move overwrites an existing destination file", function()
	local src = tmp("move-over-src.txt")
	local dst = tmp("move-over-dst.txt")
	fs.write(src, "winner")
	fs.write(dst, "loser")
	test.truthy(fs.move(src, dst))
	test.falsy(fs.exists(src))
	test.equal(fs.read(dst), "winner")
end)

--
-- stat / lstat edge cases
--

test.it("lstat on a symlink returns type=symlink", function()
	local target = tmp("lstat-target.txt")
	local link   = tmp("lstat-link")
	fs.write(target, "t")
	fs.mklink(target, link)
	local s = fs.lstat(link)
	test.truthy(s)
	test.equal(s.type, "symlink")
end)

test.it("stat on a symlink follows it and returns type=file", function()
	local target = tmp("stat-link-target.txt")
	local link   = tmp("stat-link-itself")
	fs.write(target, "t")
	fs.mklink(target, link)
	local s = fs.stat(link)
	test.truthy(s)
	test.equal(s.type, "file")
end)

--
-- readdir entry types
--

test.it("readdir reports correct entry types", function()
	local d      = tmp("readdir-types")
	local sub    = path.join(d, "subdir")
	local file   = path.join(d, "file.txt")
	local target = path.join(d, "link-target.txt")
	local link   = path.join(d, "link")
	fs.mkdir(d)
	fs.mkdir(sub)
	fs.write(file, "x")
	fs.write(target, "t")
	fs.mklink(target, link)

	local types = {}
	for entry in fs.readdir(d) do
		types[entry.name] = entry.type
	end

	test.equal(types["subdir"], "dir")
	test.equal(types["file.txt"], "file")
	-- symlink type may be "symlink" or resolved depending on OS; just check it exists
	test.truthy(types["link"])
end)

--
-- scan edge cases
--

test.it("scan returns empty table when no files match", function()
	local d = tmp("scan-nomatch")
	fs.mkdir(d)
	fs.write(path.join(d, "a.txt"), "")
	local results = fs.scan(d, "**.lua")
	test.equal(#results, 0)
end)

test.it("scan with absolute option returns absolute paths", function()
	local d = tmp("scan-absolute")
	fs.mkdir(d)
	fs.write(path.join(d, "x.lua"), "")
	local results = fs.scan(d, "**.lua", { absolute = true })
	test.equal(#results, 1)
	-- absolute path must start with the base dir
	test.truthy(results[1]:sub(1, #d) == d)
end)

test.it("scan finds files in nested directories with ** glob", function()
	local d = tmp("scan-nested")
	fs.mkdir(d)
	fs.mkdir(path.join(d, "a"))
	fs.mkdir(path.join(d, "a", "b"))
	fs.write(path.join(d, "root.lua"), "")
	fs.write(path.join(d, "a", "mid.lua"), "")
	fs.write(path.join(d, "a", "b", "deep.lua"), "")
	local results = fs.scan(d, "**.lua")
	test.equal(#results, 3)
end)

test.it("scan errors on a non-directory path", function()
	local p = tmp("scan-notdir.txt")
	fs.write(p, "x")
	local ok = pcall(fs.scan, p, "**")
	test.falsy(ok)
end)

--
-- globToPattern
--

test.it("globToPattern matches exact filename", function()
	local pat = fs.globToPattern("foo.lua")
	test.truthy(string.find("foo.lua", pat))
	test.falsy(string.find("bar.lua", pat))
end)

test.it("globToPattern * does not cross path separators", function()
	local pat = fs.globToPattern("*.lua")
	test.truthy(string.find("hello.lua", pat))
	test.falsy(string.find("a/hello.lua", pat))
end)

test.it("globToPattern ** crosses path separators", function()
	local pat = fs.globToPattern("**.lua")
	test.truthy(string.find("hello.lua", pat))
	test.truthy(string.find("a/b/hello.lua", pat))
end)

test.it("globToPattern ? matches single non-separator character", function()
	local pat = fs.globToPattern("fo?.lua")
	test.truthy(string.find("foo.lua", pat))
	test.falsy(string.find("fo.lua", pat))
end)
