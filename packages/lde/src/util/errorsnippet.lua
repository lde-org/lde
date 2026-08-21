-- Renders Lua errors the way test failures are shown: a clean "file:line:
-- message" line plus a highlighted source snippet with a caret under the
-- failing line, when the source can be located. Shared by `lde test`, `lde
-- run`, and `lde x`.
local ansi = require("ansi")
local fs = require("fs")
local path = require("path")
local highlight = require("readline.highlight")

local errorsnippet = {}

-- Lines of context shown above and below the failing line.
local CONTEXT = 2

-- Split source text into lines (dropping the empty entry left by a final newline).
---@param src string
---@return string[]
local function splitLines(src)
	local lines = {}
	local pos = 1
	while true do
		local nl = src:find("\n", pos, true)
		if nl then
			lines[#lines + 1] = src:sub(pos, nl - 1)
			pos = nl + 1
		else
			lines[#lines + 1] = src:sub(pos)
			break
		end
	end
	if #lines > 1 and lines[#lines] == "" then lines[#lines] = nil end
	return lines
end

---@param line string
---@return string
local function expandTabs(line)
	return (line:gsub("\t", "    "))
end

-- Assertion names, longest first so e.g. "greaterEqual" wins over "equal".
local ASSERT_NAMES = {
	"greaterEqual", "lessEqual", "notEqual", "deepEqual",
	"includes", "truthy", "falsy", "greater", "less", "match", "equal",
}

--- Search a line for the assertion call (or a variable named in the error
--- message) so the caret points at what actually failed.
---@param line string
---@param msg string?
---@return number col, number len
local function findCaretCol(line, msg)
	---@param word string
	---@return integer?
	local function findWord(word)
		local i = 1
		while i <= #line do
			local s = line:find(word, i, true)
			if not s then return nil end
			local e = s + #word
			local before = s > 1 and line:sub(s - 1, s - 1) or ""
			local after = line:sub(e, e)
			if not before:match("[%w_]") and not after:match("[%w_]") then
				return s
			end
			i = e
		end
	end

	-- Failing assertion call, e.g. `test.deepEqual(a, b)`.
	for _, name in ipairs(ASSERT_NAMES) do
		local i = 1
		while i <= #line do
			local s = line:find(name, i, true)
			if not s then break end
			local e = s + #name
			local before = s > 1 and line:sub(s - 1, s - 1) or ""
			if not before:match("[%w_]") then
				local j = e
				while j <= #line and line:sub(j, j):match("%s") do j = j + 1 end
				if line:sub(j, j) == "(" then
					return s, #name
				end
			end
			i = e
		end
	end

	-- A variable/field called out in a runtime error, e.g.
	-- `attempt to index a nil value (local 'x')`.
	if msg then
		local var = msg:match("^.*'([^']+)'")
		if var then
			local s = findWord(var)
			if s then return s, #var end
		end
	end

	-- Fallback: start of the statement.
	local first = line:find("%S")
	return first or 1, 1
end

---@param packageDir string
---@param msg string
local function makeRelative(packageDir, msg)
	-- Escape pattern magic characters so a path with "-", ".", etc. matches literally.
	local prefix = packageDir .. path.separator
	prefix = prefix:gsub("([^%w])", "%%%1")
	return (string.gsub(msg, prefix, ""))
end

---@param err string
---@return string? file # chunk name (brackets stripped for file paths)
---@return integer? line
---@return integer? col # compiler-reported column, when available
---@return string msg
local function parseError(err)
	-- Compile errors: strip the "Failed to compile <path>:" wrapper and prefer
	-- the compiler's "path:line:col: msg" position.
	local compileFile, compileErr = err:match("^Failed to compile (.-):\n(.*)$")
	if compileFile then
		local file, line, col, msg = compileErr:match("^(.-):(%d+):(%d+): (.*)$")
		if file then
			return path.normalize(file), tonumber(line), tonumber(col), msg
		end

		-- Moonscript reports the line only:
		--   Failed to parse:
		--    [N] >>    <source line>
		local mLine = compileErr:match("%[(%d+)%]")
		if mLine then
			return path.normalize(compileFile), tonumber(mLine), nil, (compileErr:match("^([^\n]*)"))
		end

		-- Unrecognized compiler error (e.g. Moonscript's format): parse the
		-- unwrapped text below instead of the wrapper-prefixed original.
		err = compileErr
	end

	local file, line, msg = err:match("^(.*):(%d+): (.*)$")
	if not file then return nil, nil, nil, err end

	-- The outermost match may still contain nested loader frames; take the
	-- last bracketed chunk name, which is the innermost source. Real files are
	-- chunk-named by their path; eval chunks ("-e", "...") keep their brackets.
	local inner = file:match(".*%[string \"(.-)\"%]$")
		or file:match(".*%[(.-)%]$")

	if inner and inner:match("[/\\]") then
		return inner, tonumber(line), nil, msg
	end

	return file, tonumber(line), nil, msg
end

--- Resolve the file to read for a failure. The path in the error prefix uses
--- short_src, which LuaJIT truncates to "..." + the tail of the path for long
--- chunk names, so a required module deep under target/ arrives as
--- ".../target/tests/tl-components/page-tilt.lua". The tail keeps the end of
--- the real path, so it is searched under the package dir (stripping leading
--- fragments, since the cut can land mid-component) before falling back to the
--- file the caller knows it was executing.
---@param pkgDir string
---@param msgFile string
---@param knownFile? string
---@return string? actual, string? src
local function resolveSource(pkgDir, msgFile, knownFile)
	local candidates = {}
	msgFile = msgFile:gsub("^@", "")

	if msgFile:match("^%.%.%.") then
		-- Truncated short_src: find the real file by its path tail.
		local rest = msgFile:gsub("^%.%.%.[/\\]*", "")
		while rest ~= "" do
			local candidate = path.join(pkgDir, rest)
			if fs.exists(candidate) then
				candidates[#candidates + 1] = candidate
				break
			end
			rest = rest:match("^[^/\\]*[/\\](.*)$") or ""
		end
	else
		candidates[#candidates + 1] = msgFile
		if not (msgFile:match("^/") or msgFile:match("^%a:[/\\]")) then
			candidates[#candidates + 1] = path.join(pkgDir, msgFile)
		end
	end

	if knownFile then candidates[#candidates + 1] = knownFile end
	for _, c in ipairs(candidates) do
		if fs.exists(c) then
			local src = fs.read(c)
			if src then
				-- Prefer the source tests/ copy over the built target/tests/
				-- mirror (the error line belongs to the same file).
				local testsPrefix = path.join(pkgDir, "target", "tests") .. path.separator
				if c:sub(1, #testsPrefix) == testsPrefix then
					local srcTests = path.join(pkgDir, "tests", c:sub(#testsPrefix + 1))
					if fs.exists(srcTests) then c = srcTests end
				end
				return c, src
			end
		end
	end

	return nil, nil
end

-- Print the gutter + highlighted code window for a failing line, with a caret
-- placed directly under the failing line. The caret line keeps a blank gutter
-- (a gap where the line number would be) so the arrows have vertical room.
---@param src string
---@param line number
---@param msg string?
local function printSnippet(src, line, msg)
	local lines = splitLines(src)
	if line < 1 or line > #lines then return end

	local startLine = math.max(1, line - CONTEXT)
	local endLine   = math.min(#lines, line + CONTEXT)
	local width     = #tostring(endLine)
	local indent    = "     "
	local bar       = ansi.colorize("gray", "│")
	local pad       = string.rep(" ", width)

	-- Code lines with the gutter prefix: indent + right-aligned number +
	-- separator + bar + separator. Every other line (bars, caret) reuses the
	-- same prefix so the gutter stays horizontally aligned.
	local prefix = indent .. pad .. " " .. bar .. " "
	local gutter = {}
	for ln = startLine, endLine do
		local num = string.rep(" ", width - #tostring(ln)) .. tostring(ln)
		local code = highlight(expandTabs(lines[ln]))
		gutter[ln] = indent .. ansi.colorize("gray", num) .. " " .. bar .. " " .. code
	end

	local failing = expandTabs(lines[line])
	local col, len = findCaretCol(failing, msg)
	-- An '<eof>' syntax error has nothing after the statement: point the caret
	-- at the end of the line instead of the first token.
	if msg and msg:find("<eof>", 1, true) then
		col, len = #failing + 1, 1
	end
	local caret = ansi.format("{red}{bold}%s{reset}", string.rep("^", len))

	print(indent .. pad .. " " .. bar)
	for ln = startLine, line - 1 do print(gutter[ln]) end
	print(gutter[line])
	print(prefix .. string.rep(" ", col - 1) .. caret)
	for ln = line + 1, endLine do print(gutter[ln]) end
	print(indent .. pad .. " " .. bar)
end

--- Print a failure message, followed by a source snippet when the failing
--- line can be located. Loader frames are stripped first, and `remap` lets
--- the caller rewrite the error's file (e.g. target/<name>/X -> src/X).
--- Returns false (printing nothing) when the error has no file position, so
--- the caller can fall back to its own rendering.
---@param pkgDir string
---@param err string
---@param knownFile? string # the file being executed when the error path can't be resolved
---@param remap? fun(file: string): string? # alternate path for the error file
---@return boolean rendered # true when a file:line error was printed
local function printError(pkgDir, err, knownFile, remap)
	local mfile, mline, _mcol, rest = parseError(err)
	if not mfile or not mline then
		return false
	end
	if remap then
		local mapped = remap(mfile)
		if mapped then
			knownFile = knownFile or mfile
			mfile = mapped
		end
	end
	local actual, src = resolveSource(pkgDir, mfile, knownFile)
	-- If the fallback file doesn't contain the failing line, the line belongs to
	-- a different (unresolvable, truncated) file — show the path as reported
	-- instead of pairing a wrong path with the line.
	local displayLine = mline
	if src then
		local lines = splitLines(src)
		if mline > #lines then
			if mline == #lines + 1 and #lines > 0 then
				-- '<eof>' errors report one past the last line; highlight the
				-- last line instead.
				displayLine = #lines
			else
				actual, src = nil, nil
			end
		end
	end
	ansi.printf("     {red}%s", makeRelative(pkgDir, actual or mfile) .. ":" .. mline .. ": " .. rest)
	if actual and src then
		printSnippet(src, displayLine, rest)
	end
	return true
end

--- The lde version + platform line printed under run errors, mirroring how
--- Bun annotates its errors. Kept separate so it can be extended with trace
--- frames in between.
---@return string
local function versionFooter()
	local ok, v = pcall(require, "lde.version")
	return string.format("lde v%s", ok and v or "0.11.0")
end

--- Render an error Bun-style for `lde run` / `lde x` / loose files:
---
---   2 | print(x.foo)
---     |       ^
---   error: attempt to index local 'x' (a nil value)
---       at /abs/src/init.lua:2:8
---
---   lde v0.10.0-nightly+... (Linux x64)
---
--- The source is left-aligned (no indent), the position has a column, and the
--- "at <file>:<line>:<col>" line plus the footer leave room for a full stack
--- trace to slot in between. Returns false (printing nothing) when the error
--- has no file position, so the caller can fall back to its own rendering.
---@param pkgDir string
---@param err string
---@param knownFile? string # the file being executed when the error path can't be resolved
---@param remap? fun(file: string): string? # alternate path for the error file
---@return boolean rendered # true when a file:line error was printed
local function printRunError(pkgDir, err, knownFile, remap)
	local mfile, mline, mcol, rest = parseError(err)
	if not mfile or not mline then
		return false
	end
	if remap then
		local mapped = remap(mfile)
		if mapped then
			knownFile = knownFile or mfile
			mfile = mapped
		end
	end
	local actual, src = resolveSource(pkgDir, mfile, knownFile)
	local displayLine = mline
	if src then
		local lines = splitLines(src)
		if mline > #lines then
			if mline == #lines + 1 and #lines > 0 then
				-- '<eof>' errors report one past the last line; highlight the
				-- last line instead.
				displayLine = #lines
			else
				actual, src = nil, nil
			end
		end
	end

	-- Column of the failing token. Compilers (Teal/Moonscript) report an exact
	-- column; plain Lua errors carry none, so the caret position is the best
	-- approximation.
	local col, caretLen = mcol or 1, 1
	if actual and src then
		local lines = splitLines(src)
		local startLine = math.max(1, displayLine - CONTEXT)
		local endLine = math.min(#lines, displayLine + CONTEXT)
		local width = #tostring(endLine)
		local failing = expandTabs(lines[displayLine])
		if not mcol then
			col, caretLen = findCaretCol(failing, rest)
			if rest and rest:find("<eof>", 1, true) then
				-- An '<eof>' error has nothing after the statement: point the
				-- caret at the end of the line.
				col, caretLen = #failing + 1, 1
			end
		end

		for ln = startLine, endLine do
			-- Gray gutter (line number + bar), matching the test-failure renderer.
			local num = string.format("%" .. width .. "d | ", ln)
			print(ansi.colorize("gray", num) .. highlight(expandTabs(lines[ln])))
		end
		print(string.rep(" ", width + 3 + col - 1) .. ansi.format("{red}{bold}%s{reset}", string.rep("^", caretLen)))
		ansi.printf("{red}error{reset}: %s", rest)
		ansi.printf("    at %s:%d:%d", actual, displayLine, col)
	else
		ansi.printf("{red}error{reset}: %s", rest)
		ansi.printf("    at %s:%d%s", mfile, mline, mcol and (":" .. mcol) or "")
	end
	print()
	ansi.printf("{gray}%s{reset}", versionFooter())
	return true
end

errorsnippet.printError = printError
errorsnippet.printRunError = printRunError

return errorsnippet
