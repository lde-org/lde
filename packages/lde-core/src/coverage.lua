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

--- Blank lines, comments, and the interiors of multi-line strings / block
--- comments never produce a line event, so they don't count toward the
--- executable total. Counting is done with a small Lua lexer that tracks long
--- bracket state (strings `[[...]]` / `[=[...]=]` and comments `--[[...]]`)
--- across lines, so string-literal-heavy modules (embedded driver chunks,
--- HTML templates) aren't penalized with lines that can never be covered.
---@param src string
---@param out table<number, true>? # receives the executable line numbers
---@return number
local function countExecutableLines(src, out)
	local n = 0
	local lineNo = 0
	local pos = 1
	local len = #src
	-- Level of the long bracket (string or block comment) we're inside; nil
	-- when not inside one. A level-0 opener can contain higher-level brackets.
	local level ---@type number?

	local function charAt(i) return i <= len and string.byte(src, i) or -1 end

	-- Level of a long-bracket opener at i ("[" + n*"=" + "["), or nil.
	local function openerLevelAt(i)
		if charAt(i) ~= 91 then return nil end -- '['
		local j = i + 1
		while charAt(j) == 61 do j = j + 1 end -- '='
		if charAt(j) == 91 then return j - i - 1 end -- '['
		return nil
	end

	while pos <= len do
		local nl = src:find("\n", pos, true)
		lineNo = lineNo + 1
		local lineEnd = (nl or len + 1) - 1

		local executable = false
		-- LuaJIT skips a leading shebang line; it never executes.
		if not (lineNo == 1 and charAt(pos) == 35) then -- '#'
			local i = pos
			while i <= lineEnd do
				if level then
					-- Inside a long string/comment: find the matching closer.
					local lit = "]" .. string.rep("=", level) .. "]"
					local close = src:find(lit, i, true)
					if not close or close > lineEnd then
						break -- still inside; the rest of the line is string/comment
					end
					i = close + level + 2
					level = nil
					if i > lineEnd then break end -- closer ends the line
				end

				local c = charAt(i)
				if c == 45 and charAt(i + 1) == 45 then -- '--'
					local lvl = openerLevelAt(i + 2)
					if lvl then
						level = lvl
						i = i + 2
					else
						break -- line comment to end of line
					end
				elseif c == 34 or c == 39 then -- '"' or "'"
					-- Regular string literal (cannot span lines).
					local j = i + 1
					while j <= lineEnd do
						local sc = charAt(j)
						if sc == 92 then -- '\\'
							j = j + 2
						elseif sc == c then
							j = j + 1
							break
						else
							j = j + 1
						end
					end
					executable = true
					i = j
				elseif c == 91 then -- '['
					local lvl = openerLevelAt(i)
					if lvl then
						level = lvl
						i = i + lvl + 2
					else
						executable = true
						i = i + 1
					end
				elseif c == 32 or c == 9 or c == 13 then -- ' ' '\t' '\r'
					i = i + 1
				else
					executable = true
					i = i + 1
				end
			end
		end

		if executable then
			n = n + 1
			if out then out[lineNo] = true end
		end
		pos = (nl or len) + 1
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
