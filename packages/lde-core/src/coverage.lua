--- Line coverage collection for `lde test --coverage`.
---
--- A line hook is installed on each guest test state
--- (state:setHook(hook, "line")) and records every executed line in files
--- belonging to the package under test. Everything else the guest loads —
--- dependencies, the test framework, the guest standard library — is
--- filtered out by the in-scope directory prefixes. Hits are shared across
--- all test files (each file runs in its own fresh state) and merged into a
--- single report by Coverage:compute().

local fs   = require("fs")
local path = require("path")

---@class lde.CoverageFile
---@field file      string # absolute path of the covered source file
---@field executable number # lines that can hold bytecode (non-blank, non-comment)
---@field covered   number # distinct lines executed by the test suite

---@class lde.Coverage
---@field prefixes string[] # absolute dirs (with trailing separator) whose files are in scope
---@field baseDir  string?   # package dir; relative chunk names (dofile/loadfile) resolve against it
---@field hits     table<string, table<number, number>> # file -> line -> hit count
local Coverage = {}
Coverage.__index = Coverage

---@param prefixes string[] # absolute dirs (with trailing separator) whose files are in scope
---@param baseDir  string?   # package dir used to resolve relative chunk names
---@return lde.Coverage
function Coverage.new(prefixes, baseDir)
	return setmetatable({ prefixes = prefixes, baseDir = baseDir, hits = {} }, Coverage)
end

--- Line hook handler; install via `state:setHook(hook, "line")`. Only "line"
--- events for files under one of the collector's prefixes are recorded.
--- `info.source` is "@<chunk path>" — the path require resolved from the
--- guest's package.path, i.e. the package's built output under target/<name>.
---
---@param event string
---@param info  { source: string, currentline: number }
function Coverage:hook(event, info)
	if event ~= "line" then return end
	local src = info.source
	if not src or src:sub(1, 1) ~= "@" then return end
	local file = src:sub(2)
	-- Relative chunk names come from dofile/loadfile with relative paths;
	-- resolve them against the package dir so the prefix filter can match.
	if not (file:sub(1, 1) == "/" or file:sub(1, 1) == "\\" or file:match("^%a:[/\\]")) then
		if not self.baseDir then return end
		file = path.join(self.baseDir, file)
	end
	for i = 1, #self.prefixes do
		if file:sub(1, #self.prefixes[i]) == self.prefixes[i] then
			local lines = self.hits[file]
			if not lines then
				lines = {}
				self.hits[file] = lines
			end
			lines[info.currentline] = (lines[info.currentline] or 0) + 1
			return
		end
	end
end

--- Blank and comment-only lines never produce a line event, so they don't
--- count toward the executable total. Block comments (`--[[ ... ]]`) whose
--- interior lines don't start with "--" are counted as executable — the same
--- simple heuristic other line-hook coverage tools (luacov) accept.
---@param line string
---@return boolean
local function isExecutableLine(line)
	local first = line:find("%S")
	if not first then return false end
	return line:sub(first, first + 1) ~= "--"
end

---@param src string
---@param out table<number, true>? # receives the executable line numbers
---@return number
local function countExecutableLines(src, out)
	local n = 0
	local lineNo = 0
	local pos = 1
	while pos <= #src do
		local nl = src:find("\n", pos, true)
		lineNo = lineNo + 1
		local line
		if nl then
			line = src:sub(pos, nl - 1)
			pos = nl + 1
		else
			line = src:sub(pos)
			pos = #src + 1
		end
		if isExecutableLine(line) then
			n = n + 1
			if out then out[lineNo] = true end
		end
	end
	return n
end

--- Compute per-file stats by reading each hit file's source. Files that can
--- no longer be read (deleted mid-run) are skipped.
---
---@return lde.CoverageFile[] files
---@return number totalExecutable
---@return number totalCovered
function Coverage:compute()
	local files = {}
	local totalExecutable, totalCovered = 0, 0
	for file, lines in pairs(self.hits) do
		local src = fs.read(file)
		if src then
			local execLines = {}
			local executable = countExecutableLines(src, execLines)
			local covered = 0
			for ln in pairs(lines) do
				if execLines[ln] then covered = covered + 1 end
			end
			files[#files + 1] = {
				file = file,
				executable = executable,
				covered = covered,
			}
			totalExecutable = totalExecutable + executable
			totalCovered = totalCovered + covered
		end
	end
	return files, totalExecutable, totalCovered
end

return Coverage
