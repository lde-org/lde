--- Line coverage for `lde test --coverage`: a line hook per guest test state records
--- executed lines under the package's prefixes. Each test file runs in a fresh state,
--- so hits are accumulated across files and merged by Coverage:compute().

const fs   = require("fs")
const path = require("path")

---@class lde.CoverageFile
---@field file      string # absolute path of the covered source file
---@field executable number # lines that can hold bytecode (non-blank, non-comment)
---@field covered   number # distinct lines executed by the test suite

---@class lde.Coverage
---@field prefixes string[] # absolute dirs (with trailing separator) whose files are in scope
---@field baseDir  string?   # package dir; relative chunk names (dofile/loadfile) resolve against it
---@field hits     table<string, table<number, number>> # file -> line -> hit count
const Coverage = {}
Coverage.__index = Coverage

---@param prefixes string[] # absolute dirs (with trailing separator) whose files are in scope
---@param baseDir  string?   # package dir used to resolve relative chunk names
function Coverage.new(prefixes, baseDir)
	return setmetatable({ prefixes = prefixes, baseDir = baseDir, hits = {} }, Coverage)
end

--- `info.source` is "@<chunk path>" — the path require resolved from the guest's package.path, i.e. the package's built output under target/<name>.
---@param event string
---@param info  { source: string, currentline: number }
function Coverage:hook(event, info)
	if event ~= "line" then return end
	local src = info.source
	if not src or src:sub(1, 1) ~= "@" then return end
	local file = src:sub(2)
	-- Relative chunk names (dofile/loadfile) resolve against the package dir; normalize to the native separator since chunk names use "/" on every platform.
	if not (file:sub(1, 1) == "/" or file:sub(1, 1) == "\\" or file:match("^%a:[/\\]")) then
		if not self.baseDir then return end
		file = (path.join(self.baseDir, file):gsub("\\", "/")):gsub("/", path.separator)
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

--- Skips non-executable lines using a lexer that tracks long-bracket state (strings/comments) across lines, so string-literal-heavy modules aren't penalized with lines that can never be covered.
---@param src string
---@param out table<number, true>? # receives the executable line numbers
---@return number
local function countExecutableLines(src, out)
	local n = 0
	local lineNo = 0
	local pos = 1
	const len = #src
	-- Long-bracket nesting level we're inside (nil when none); a level-0 opener can contain higher-level brackets.
	local level ---@type number?

	---@param i number
	---@return integer
	local function charAt(i) return i <= len ? string.byte(src, i) : -1 end

	---@param i number
	---@return integer?
	local function openerLevelAt(i)
		if charAt(i) ~= 91 then return nil end -- '['
		local j = i + 1
		while charAt(j) == 61 do j = j + 1 end -- '='
		if charAt(j) == 91 then return j - i - 1 end -- '['
		return nil
	end

	while pos <= len do
		const nl = src:find("\n", pos, true)
		lineNo += 1
		const lineEnd = (nl or len + 1) - 1

		local executable = false
		-- LuaJIT skips a leading shebang line; it never executes.
		if not (lineNo == 1 and charAt(pos) == 35) then -- '#'
			local i = pos
			while i <= lineEnd do
				if level then
					local lit = "]" .. string.rep("=", level) .. "]"
					const close = src:find(lit, i, true)
					if not close or close > lineEnd then
						break -- still inside; the rest of the line is string/comment
					end
					i = close + level + 2
					level = nil
					if i > lineEnd then break end -- closer ends the line
				end

				const c = charAt(i)
				if c == 45 and charAt(i + 1) == 45 then -- '--'
					local lvl = openerLevelAt(i + 2)
					if lvl then
						level = lvl
						i += 2
					else
						break -- line comment to end of line
					end
				elseif c == 34 or c == 39 then -- '"' or "'"
					local j = i + 1
					while j <= lineEnd do
						const sc = charAt(j)
						if sc == 92 then -- '\\'
							j = j + 2
						elseif sc == c then
							j += 1
							break
						else
							j += 1
						end
					end
					executable = true
					i = j
				elseif c == 91 then -- '['
					local lvl = openerLevelAt(i)
					if lvl then
						level = lvl
						i += lvl + 2
					else
						executable = true
						i += 1
					end
				elseif c == 32 or c == 9 or c == 13 then -- ' ' '\t' '\r'
					i = i + 1
				else
					executable = true
					i += 1
				end
			end
		end

		if executable then
			n += 1
			if out then out[lineNo] = true end
		end
		pos = (nl or len) + 1
	end
	return n
end

---@return lde.CoverageFile[] files
---@return number totalExecutable
---@return number totalCovered
function Coverage:compute()
	local files = {}
	local totalExecutable, totalCovered = 0, 0
	for file, lines in pairs(self.hits) do
		local src = fs.read(file)
		if src then
			const execLines = {}
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
			totalExecutable += executable
			totalCovered += covered
		end
	end
	return files, totalExecutable, totalCovered
end

return Coverage
