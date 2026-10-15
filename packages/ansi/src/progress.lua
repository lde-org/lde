-- Progress diagnostics: ansi.progress / ansi.installProgress plus the
-- shared helpers (bar rendering, byte/elapsed formatting, emoji detection).
const ansi = require("ansi")
const core = ansi._core
const colors = core.colors
const ESC = core.escape
const columns = core.columns
local now = core.now

-- ─── Emoji support ───────────────────────────────────────────────────────
-- Emoji (e.g. the 🪨 rock marker in `lde search`) render only when the
-- terminal has an emoji font with glyph fallback. A program can't query glyph
-- coverage, so this is a heuristic over the environment: block the known-bad
-- cases (dumb/linux terminals, non-UTF-8 locales) and let NO_EMOJI force it
-- off. Most modern terminals fall through to true.
local emojiSupported = true
do
	local term = os.getenv("TERM") or ""
	if term == "dumb" or term == "linux" then
		emojiSupported = false
	end

	-- Non-UTF-8 locales can't even encode emoji.
	const locale = os.getenv("LC_ALL") or os.getenv("LC_CTYPE") or os.getenv("LANG") or ""
	const l = locale:lower()
	if locale == "" or locale == "C" or locale == "POSIX"
		or (not l:find("utf-8", 1, true) and not l:find("utf8", 1, true)) then
		emojiSupported = false
	end

	const noEmoji = os.getenv("NO_EMOJI")
	if noEmoji and noEmoji ~= "0" then
		emojiSupported = false
	end
end

--- Whether the terminal can be expected to render emoji glyphs.
---@return boolean
local function supportsEmoji()
	return emojiSupported
end

--- Shared no-op progress handle returned in quiet mode.
const silentProgress = {
	update = function() end,
	setLabel = function() end,
	done = function() end,
	fail = function() end,
}

-- progress: animated spinner with elapsed time.
-- update(ratio, info) — ratio is 0–1 or nil (indeterminate); info is optional status text.
-- setLabel(msg) — swap the label shown by the spinner and used by done/fail.
-- done(msg) / fail(msg) — finalize with checkmark or cross.

const BAR_WIDTH = 20

---@param seconds number
local function formatElapsed(seconds)
	if seconds < 0.1 then
		return string.format("%.0fms", seconds * 1000)
	elseif seconds < 10 then
		return string.format("%.2fs", seconds)
	elseif seconds < 60 then
		return string.format("%.1fs", seconds)
	else
		local m = math.floor(seconds / 60)
		const s = math.floor(seconds % 60)
		return string.format("%dm%ds", m, s)
	end
end

-- One filled bar run, colored by the bar's ratio in discrete stock-ANSI
-- steps (red → orange → yellow → green). The terminal remaps these codes to
-- the user's theme, unlike a fixed truecolor gradient — and they render on
-- any color terminal, not just truecolor ones.
---@param ratio number?
local function renderBar(ratio)
	if not ratio then return nil end
	local filled = math.floor(ratio * BAR_WIDTH)
	if filled < 0 then filled = 0 end
	if filled > BAR_WIDTH then filled = BAR_WIDTH end

	const body = string.rep("=", filled)
	const head = filled < BAR_WIDTH ? ">" : ""
	local colored = body .. head
	if colored ~= "" then
		-- colors[] entries are empty strings when colors are disabled, so this
		-- is a no-op there.
		const step = ratio < 0.25 and "red"
			or ratio < 0.5 and "orange"
			or ratio < 0.75 and "yellow"
			or "green"
		colored = colors[step] .. colored .. colors.reset
	end
	const rest = string.rep(" ", BAR_WIDTH - filled - (head ~= "" ? 1 : 0))
	return colors.gray .. "[" .. colors.reset .. colored .. rest .. colors.gray .. "]" .. colors.reset
end

---@class ansi.Progress
---@field update fun(self: ansi.Progress, ratio: number?, info: string?)
---@field setLabel fun(self: ansi.Progress, label: string)
---@field done fun(self: ansi.Progress, msg: string?, seconds: number?) # seconds overrides the handle's own elapsed (a parent re-rendering a recorded result)
---@field fail fun(self: ansi.Progress, msg: string?)
---@field clear fun(self: ansi.Progress) # erase the live line without printing (caller writes its own output next)

--- Progress is diagnostics, and stdout is the command's data: `eval "$(lde
--- completion bash)"`, `lde <tool> | ...` and a tool wrapper run from a shell rc
--- all read stdout as a payload, so a line written there corrupts the caller.
--- The test reporter is the one caller whose progress IS its output, hence the
--- `stream` opt-in. Resolved per call so an injected stream (tests) is honored.
---@param label string
---@param opts { indent: boolean?, stream: "stdout"|"stderr"?, live: boolean? }? # indent=false prints flush-left (compact install output); default indented (test runner); live=false prints only the final line, for callers whose lines share the stream with other writers (sharded test files)
---@return ansi.Progress
local function progress(label, opts)
	if ansi.isQuiet then return silentProgress end
	const stream = opts?.stream ?? "stderr"
	local out = stream == "stdout" ? io.stdout : io.stderr
	-- Parallel writers (sharded test files) turn the live line off: several
	-- redraws would fight over one terminal, and each erase escape would wipe
	-- the others' finished lines.
	local isTerminal = (opts == nil or opts.live ~= false)
		and (stream == "stdout" ? ansi.isTTY : ansi.isStderrTTY)
	local startTime = now()
	local indent = opts == nil or opts.indent ~= false
	local donePrefix, failPrefix, livePrefix = "  ✓ ", "  ✗ ", "  - "
	if not indent then
		donePrefix, failPrefix, livePrefix = "✓ ", "✗ ", "- "
	end

	if not isTerminal then
		return {
			update = function() end,
			clear = function() end,
			setLabel = function(_, newLabel)
				label = newLabel
			end,
			done = function(_, msg, seconds)
				local elapsed = formatElapsed(seconds or (now() - startTime))
				out:write(colors.green ..
				donePrefix ..
				colors.reset .. (msg or label) .. " " .. colors.gray .. "(" .. elapsed .. ")" .. colors.reset .. "\n")
				out:flush()
			end,
			fail = function(_, msg)
				out:write(colors.red .. failPrefix .. colors.reset .. (msg or label) .. "\n")
				out:flush()
			end
		}
	end

	local lastRendered = nil
	local lastRatio, lastInfo
	---@type integer # physical rows the previous frame occupied (the line may wrap)
	local lastLines = 0

	--- Erase the previously rendered frame. It may have wrapped to several
	--- rows on a narrow terminal: move to its first row and clear to the end
	--- of the screen.
	local function clearLine()
		if lastLines > 1 then out:write(ESC .. (lastLines - 1) .. "A") end
		out:write("\r" .. ESC .. "J")
		lastLines = 0
		out:flush()
	end

	---@param ratio number?
	---@param info string?
	local function render(ratio, info)
		lastRatio, lastInfo = ratio, info
		local barStr = renderBar(ratio)
		const pct = ratio ? string.format("%3d%%", math.floor(ratio * 100)) : nil
		local elapsed = formatElapsed(now() - startTime)

		if pct == lastRendered then return end
		lastRendered = pct

		local line = colors.gray .. livePrefix .. colors.reset .. label
		if barStr then
			line ..= " " .. barStr .. " " .. pct
		end
		if info then
			line ..= " " .. info
		end
		line ..= " " .. colors.gray .. elapsed .. colors.reset

		clearLine()
		out:write(line)
		out:flush()
		-- Bytes == display columns for the ASCII frame; how many rows the next
		-- clear must cover if the line wrapped.
		const plain = line:gsub("\27%[[0-9;]*[A-Za-z]", "")
		lastLines = math.ceil(#plain / columns)
	end

	render(nil, nil)

	return {
		update = function(_, ratio, info)
			render(ratio, info)
		end,
		setLabel = function(_, newLabel)
			label = newLabel
			lastRendered = false -- force the next render past the pct dedupe check
			render(lastRatio, lastInfo)
		end,
		--- Erase the live line without printing anything, so a caller can write a
		--- block of output and then resume updating below it.
		clear = function()
			clearLine()
			lastRendered = false -- force the next update past the pct dedupe check
		end,
		done = function(_, msg, seconds)
			local elapsed = formatElapsed(seconds or (now() - startTime))
			clearLine()
			out:write(colors.green ..
			donePrefix ..
			colors.reset .. (msg or label) .. " " .. colors.gray .. "(" .. elapsed .. ")" .. colors.reset .. "\n")
			out:flush()
		end,
		fail = function(_, msg)
			clearLine()
			out:write(colors.red .. failPrefix .. colors.reset .. (msg or label) .. "\n")
			out:flush()
		end
	}
end

-- ─── Install progress ────────────────────────────────────────────────────
-- Live region for the dependency install pass. Each dependency currently
-- being materialized or built gets its own row, appearing when its work
-- starts and clearing when it finishes: `marker label built/total elapsed`,
-- where built/total is how many of the packages that dependency pulls in are
-- built. The marker is picked lazily from what is already known: 🔧 for an
-- lde package (git/path), 🪨 for a luarocks package, 🛠️ once a build.lua is
-- discovered. Below the rows sits the total bar (gray brackets, a single
-- red→green fill in discrete theme steps) with the install-wide built/building count. Nothing is
-- committed to the scrollback, so an install prints exactly one line (the
-- summary) plus whatever the caller prints. Non-TTY output prints only the
-- summary.

---@type table<string, string> # row marker key -> emoji
const INSTALL_EMOJI = {
	wrench = "🔧", -- lde package (git/path): copied or symlinked
	rock = "🪨", -- luarocks package
	tools = "🛠️", -- package running a build.lua
}

---@class ansi.InstallProgress
---@field setCurrent fun(self: ansi.InstallProgress, label: string, kind?: "wrench"|"rock"|"tools") # spawn (or refresh) a dependency's row; resets its timer
---@field setDepCount fun(self: ansi.InstallProgress, label: string, built: integer, total: integer) # update a row's built/building count
---@field update fun(self: ansi.InstallProgress, ratio: number?, info: string?) # move the total progress bar
---@field finish fun(self: ansi.InstallProgress, label: string) # remove a finished dependency's row
---@field done fun(self: ansi.InstallProgress, summary: string) # finalize: clear the region, print `✓ summary`
---@field fail fun(self: ansi.InstallProgress, msg: string) # finalize on error: clear the region, print `✗ msg`
---@field clear fun(self: ansi.InstallProgress) # clear the region without printing anything (caller prints its own summary)

---@param fallbackLabel string # label shown on the total line while nothing is building
---@return ansi.InstallProgress
local function installProgress(fallbackLabel)
	local out = io.stderr
	local isTerminal = ansi.isStderrTTY
	local startTime = now()
	---@type string[] # active dependency labels, in build-start order
	local rows = {}
	---@type table<string, number> # label -> build start time
	const rowStart = {}
	---@type table<string, "wrench"|"rock"|"tools"> # label -> work-kind marker
	const rowKind = {}
	---@type table<string, { built: integer, total: integer }> # label -> per-dependency built/building count
	const depCount = {}
	local ratio, info = nil, nil
	local lastRatio, lastInfo = nil, nil
	local lastRowKey = ""
	local lastDraw = 0
	---@type integer # rows the previous frame occupied
	local lastLines = 0

	--- Erase the previously rendered live region: move to its first row and
	--- clear to the end of the screen. Each row is a single short line, so no
	--- horizontal clearing is needed.
	local function clearRegion()
		if not isTerminal then return end
		if lastLines > 1 then out:write(ESC .. (lastLines - 1) .. "A") end
		out:write("\r" .. ESC .. "J")
		lastLines = 0
		out:flush()
	end

	--- Write the live region (TTY only). Deduped to ~10Hz so the elapsed
	--- counters can animate without spamming the terminal.
	local function render()
		if not isTerminal then return end
		const nowT = now()
		local rowKey = table.concat(rows, "\0")
		if rowKey == lastRowKey and ratio == lastRatio and info == lastInfo and nowT - lastDraw < 0.1 then
			return
		end
		lastRowKey, lastRatio, lastInfo, lastDraw = rowKey, ratio, info, nowT

		local lines = {}
		for _, label in ipairs(rows) do
			-- Each row: `marker label built/total elapsed`. The built/total
			-- count is shown only when the dependency pulls in other packages
			-- (a leaf's `0/1` is noise).
			const c = depCount[label]
			const count = (c and c.total > 1) ? (" " .. colors.gray .. c.built .. "/" .. c.total .. colors.reset) : ""
			const marker = supportsEmoji() ? INSTALL_EMOJI[rowKind[label] or "wrench"] : ""
			lines[#lines + 1] = marker
				.. (marker ~= "" ? " " : "") .. label .. count
				.. " " .. colors.gray .. formatElapsed(nowT - rowStart[label]) .. colors.reset
		end

		local total = ""
		local barStr = renderBar(ratio)
		if barStr then total ..= barStr end
		if info then total ..= " " .. colors.gray .. info .. colors.reset end
		if #rows == 0 and not barStr and not info then total ..= fallbackLabel end
		lines[#lines + 1] = total

		clearRegion()
		out:write(table.concat(lines, "\n"))
		out:flush()
		lastLines = #lines
	end

	const progress = {}

	function progress:setCurrent(label, kind)
		if not rowStart[label] then rows[#rows + 1] = label end
		rowStart[label] = now()
		rowKind[label] = kind or "wrench"
		render()
	end

	function progress:setDepCount(label, built, total)
		depCount[label] = { built = built, total = total }
		render()
	end

	function progress:update(newRatio, newInfo)
		ratio, info = newRatio, newInfo
		render()
	end

	function progress:finish(label)
		for i, l in ipairs(rows) do
			if l == label then
				table.remove(rows, i)
				break
			end
		end
		rowStart[label] = nil
		rowKind[label] = nil
		depCount[label] = nil
		render()
	end


	function progress:done(summary)
		clearRegion()
		out:write(colors.green ..
			"✓ " ..
			colors.reset .. summary .. " " .. colors.gray .. "(" .. formatElapsed(now() - startTime) .. ")" .. colors.reset .. "\n")
		out:flush()
	end

	function progress:fail(msg)
		clearRegion()
		out:write(colors.red .. "✗ " .. colors.reset .. msg .. "\n")
		out:flush()
	end

	function progress:clear()
		clearRegion()
	end

	render()
	return progress
end

-- Format a byte count for human display.
---@param bytes number
local function formatBytes(bytes)
	if bytes < 1024 then return string.format("%d B", bytes) end
	if bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024) end
	if bytes < 1024 * 1024 * 1024 then return string.format("%.1f MB", bytes / (1024 * 1024)) end
	return string.format("%.2f GB", bytes / (1024 * 1024 * 1024))
end

const M = {}

M.progress = progress
M.installProgress = installProgress
M.formatBytes = formatBytes
M.formatElapsed = formatElapsed
M.supportsEmoji = supportsEmoji

return M
