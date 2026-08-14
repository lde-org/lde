-- Unit tests for the coverage collector itself (lde-core.coverage): the line
-- hook's filtering rules and the report computation. The CLI-level format test
-- lives in packages/lde/tests/coverage.test.lua; this covers the internals.
local test = require("lde-test")

local fs = require("fs")
local env = require("env")
local path = require("path")

local Coverage = require("lde-core.coverage")

local tmpBase = path.join(env.tmpdir(), "lde-coverage-unit-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

local srcDir = path.join(tmpBase, "src")
fs.mkdir(srcDir)
local srcFile = path.join(srcDir, "mod.lua")
fs.write(srcFile, [[
-- a comment line
local M = {}

function M.hi()
	return "hi"
end

return M
]])

local coverage ---@type lde.Coverage
local function fresh()
	coverage = Coverage.new({ srcDir .. path.separator }, tmpBase)
end

--
-- Coverage:hook — what gets recorded
--

test.it("hook records line hits for in-scope files", function()
	fresh()
	coverage:hook("line", { source = "@" .. srcFile, currentline = 2 })
	coverage:hook("line", { source = "@" .. srcFile, currentline = 2 })
	coverage:hook("line", { source = "@" .. srcFile, currentline = 4 })

	local hits = coverage.hits[srcFile]
	test.truthy(hits)
	test.equal(hits[2], 2)
	test.equal(hits[4], 1)
end)

test.it("hook ignores non-line events", function()
	fresh()
	coverage:hook("call", { source = "@" .. srcFile, currentline = 3 })
	test.equal(next(coverage.hits), nil)
end)

test.it("hook ignores non-file chunk names (e.g. [string \"...\"])", function()
	fresh()
	coverage:hook("line", { source = "[string \\\"chunk\\\"]", currentline = 1 })
	coverage:hook("line", { source = "=stdin", currentline = 1 })
	test.equal(next(coverage.hits), nil)
end)

test.it("hook ignores out-of-scope files", function()
	fresh()
	coverage:hook("line", { source = "@" .. path.join(tmpBase, "other", "x.lua"), currentline = 1 })
	test.equal(next(coverage.hits), nil)
end)

test.it("hook resolves relative chunk names against the package dir", function()
	fresh()
	coverage:hook("line", { source = "@src/mod.lua", currentline = 2 })

	local hits = coverage.hits[srcFile]
	test.truthy(hits, "relative source must resolve against baseDir")
	test.equal(hits[2], 1)
end)

test.it("hook drops relative sources when no baseDir is set", function()
	coverage = Coverage.new({ srcDir .. path.separator }, nil)
	coverage:hook("line", { source = "@mod.lua", currentline = 2 })
	test.equal(next(coverage.hits), nil)
end)

--
-- Coverage:compute — executable-line counting and totals
--

test.it("compute counts only executable lines (comments/blank excluded)", function()
	fresh()
	-- Executable lines of the fixture: 2,4,5,6,8 (line 1 is a comment; 3 and 7
	-- are blank, which never emit line events).
	coverage:hook("line", { source = "@" .. srcFile, currentline = 4 })
	coverage:hook("line", { source = "@" .. srcFile, currentline = 8 })

	local files, totalExec, totalCovered = coverage:compute()
	test.equal(#files, 1)
	test.equal(files[1].file, srcFile)
	test.equal(files[1].executable, 5)
	test.equal(files[1].covered, 2)
	test.equal(totalExec, 5)
	test.equal(totalCovered, 2)
end)

test.it("compute skips files that can no longer be read", function()
	fresh()
	coverage:hook("line", { source = "@" .. srcFile, currentline = 4 })
	local gone = path.join(srcDir, "deleted.lua")
	coverage:hook("line", { source = "@" .. gone, currentline = 1 })
	fs.delete(gone)

	local files, totalExec, totalCovered = coverage:compute()
	test.equal(#files, 1, "unreadable file must be skipped")
	test.equal(files[1].file, srcFile)
	test.truthy(totalExec > 0)
	test.truthy(totalCovered > 0)
end)
