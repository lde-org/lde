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

	-- Drain the mkdir event and let the watcher register the new subdir
	local deadline = os.clock() + 1
	while os.clock() < deadline do w.poll() end

	local before = #events
	fs.write(path.join(sub, "file.txt"), "hi")

	deadline = os.clock() + 1
	while #events == before and os.clock() < deadline do
		w.poll()
	end

	w.close()
	test.truthy(#events > before)
end)
