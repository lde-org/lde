local ansi = require("ansi")
local env = require("env")
local fs = require("fs")
local json = require("json")
local path = require("path")

local lde = require("lde-core")
local prompt = require("lde.util.prompt")

-- Distinct, contrasting colors for the top 5 dependencies; lower ranks and the
-- bar remainder render in gray. Colors are rank-stable so the bar, the legend
-- and the list always agree.
---@type ansi.Color[]
local barColors = { "red", "green", "yellow", "blue", "magenta" }
local BAR_WIDTH = 40
local VIEW_HEIGHT = 5

---@param bytes number
---@param denominator number
---@return string
local function pctStr(bytes, denominator)
	local pct = bytes / denominator * 100
	if pct >= 10 then return string.format("%.0f%%", pct) end
	return string.format("%.1f%%", pct)
end

---@param count number
---@return string
local function fileCount(count)
	return count .. (count == 1 and " file" or " files")
end

---@param bytes number
---@return string
local function sizeStr(bytes)
	return ansi.colorize("cyan", ansi.formatBytes(bytes))
end

---@param bytes number
---@param denominator number
---@return string
local function pctColored(bytes, denominator)
	return ansi.colorize("cyan", pctStr(bytes, denominator))
end

--- The file's name relative to its dependency: the module name minus the
--- `entry.` prefix; the entry's own init module renders as init.lua.
---@param entry lde.bloat.Entry
---@param file lde.bloat.File
---@return string
local function displayName(entry, file)
	local prefix = entry.name .. "."
	if file.name:sub(1, #prefix) == prefix then
		return file.name:sub(#prefix + 1)
	end
	if file.name == entry.name then
		return file.kind == "native" and file.name or "init.lua"
	end
	return file.name
end

---@param entry lde.bloat.Entry
---@param index number
---@param denominator number
---@param isExpanded boolean? # nil in the static view, which shows no marker
---@return string
local function entryRow(entry, index, denominator, isExpanded)
	local marker = ""
	if isExpanded ~= nil then
		marker = isExpanded and "[+] " or "[ ] "
	end
	local rootMarker = entry.isRoot and ansi.colorize("gray", " (your code)") or ""
	return marker
		.. ansi.colorize(barColors[index] or "gray", entry.name) .. "  "
		.. sizeStr(entry.bytes) .. " (" .. pctColored(entry.bytes, denominator) .. ")"
		.. rootMarker
end

---@param entry lde.bloat.Entry
---@param file lde.bloat.File
---@param denominator number
---@return string
local function fileRow(entry, file, denominator)
	local suffix = file.kind == "native" and ansi.colorize("gray", " (native)") or ""
	return "├─ " .. displayName(entry, file) .. suffix .. "  "
		.. sizeStr(file.bytes) .. " (" .. pctColored(file.bytes, denominator) .. ")"
end

---@class lde.bloat.BarSegment
---@field name string
---@field color ansi.Color
---@field bytes number

--- The proportional bar: each of the top 5 entries gets a colored run of
--- characters proportional to its share of the bundle; the remainder (lower
--- ranks plus rounding) is gray. Returns the bar and the legend entries for
--- its colored segments.
---@param entries lde.bloat.Entry[]
---@param denominator number
---@return string
---@return lde.bloat.BarSegment[]
local function barAndLegend(entries, denominator)
	---@type { color: ansi.Color, count: number }[]
	local segments = {}
	---@type lde.bloat.BarSegment[]
	local legend = {}
	local used = 0

	for i = 1, 5 do
		local entry = entries[i]
		if not entry then break end
		local color = barColors[i]
		segments[#segments + 1] = {
			color = color,
			count = math.floor(entry.bytes / denominator * BAR_WIDTH),
		}
		legend[#legend + 1] = { name = entry.name, color = color, bytes = entry.bytes }
		used = used + segments[#segments].count
	end

	-- Floor rounding can leave a small dep with a zero-width segment; give
	-- every shown dep one character so its legend color is visible in the bar.
	for _, segment in ipairs(segments) do
		if used < BAR_WIDTH and segment.count == 0 then
			segment.count = 1
			used = used + 1
		end
	end
	segments[#segments + 1] = { color = "gray", count = BAR_WIDTH - used }

	local line = {}
	for _, segment in ipairs(segments) do
		if segment.count > 0 then
			line[#line + 1] = ansi.colorize(segment.color, string.rep("█", segment.count))
		end
	end
	return table.concat(line), legend
end

---@param legend lde.bloat.BarSegment[]
---@param denominator number
---@param restBytes number # bytes held by deps ranked 6+ (the gray remainder)
---@return string[]
local function legendLines(legend, denominator, restBytes)
	local lines = {}
	for _, item in ipairs(legend) do
		lines[#lines + 1] = ansi.colorize(item.color, "██") .. " "
			.. ansi.colorize(item.color, item.name) .. " "
			.. sizeStr(item.bytes) .. " (" .. pctColored(item.bytes, denominator) .. ")"
	end
	if restBytes > 0 then
		lines[#lines + 1] = ansi.colorize("gray", "██ rest") .. " "
			.. sizeStr(restBytes) .. " (" .. pctColored(restBytes, denominator) .. ")"
	end
	return lines
end

--- Print the title, counts, total, bar and legend. Returns false when the
--- bundle is empty (a note was printed instead).
---@param report lde.bloat.Report
---@param binaryPath string?
---@param binaryBytes number?
---@return boolean
local function renderPreamble(report, binaryPath, binaryBytes)
	local hasBinary = binaryBytes ~= nil and binaryBytes > 0
	if hasBinary then ---@cast binaryBytes -nil
	end
	local denominator = report.totalBytes

	if hasBinary then
		ansi.printf("{bold}Bloat report:{reset} %s {gray}(binary: %s - %s)",
			report.rootName, binaryPath, sizeStr(binaryBytes))
	else
		ansi.printf("{bold}Bloat report:{reset} %s", report.rootName)
	end
	ansi.printf("Lua: {bold}%s{reset} - %s (bytecode)",
		fileCount(report.luaFiles), sizeStr(report.luaBytes))
	ansi.printf("Native: {bold}%s{reset} - %s",
		fileCount(report.nativeFiles), sizeStr(report.nativeBytes))
	if hasBinary then
		local overhead = binaryBytes - report.totalBytes
		ansi.printf("{bold}Total:{reset} %s {gray}(binary){reset} - %s embedded (%d files)",
			sizeStr(binaryBytes), sizeStr(report.totalBytes), report.luaFiles + report.nativeFiles)
		if overhead > 0 then
			ansi.printf("{bold}LuaJIT runtime + C glue:{reset} %s (%s of binary)",
				sizeStr(overhead), pctColored(overhead, binaryBytes))
		end
	else
		ansi.printf("{bold}Total:{reset} %s embedded (%d files)",
			sizeStr(report.totalBytes), report.luaFiles + report.nativeFiles)
	end

	if #report.entries == 0 then
		ansi.note("Nothing bundled - no Lua modules found in target/ (is src/ present and non-empty?)")
		return false
	end

	local restBytes = 0
	for i = 6, #report.entries do
		restBytes = restBytes + report.entries[i].bytes
	end

	print("")
	local bar, legend = barAndLegend(report.entries, denominator)
	print(bar)
	print("") -- gap between the bar and its legend
	for _, line in ipairs(legendLines(legend, denominator, restBytes)) do
		print(line)
	end
	print("")
	return true
end

---@param report lde.bloat.Report
---@param denominator number
local function renderRows(report, denominator)
	for i, entry in ipairs(report.entries) do
		print(entryRow(entry, i, denominator))
		for _, file in ipairs(entry.files) do
			print(fileRow(entry, file, denominator))
		end
	end
end

---@class lde.bloat.UIRow
---@field entryIndex number
---@field isEntry boolean
---@field text string

--- Interactive tree browser: dependencies start collapsed; ↑/↓ (or j/k) move a
--- cursor through a 5-row window, Enter toggles a dependency open/closed,
--- q/Esc/Ctrl+C quits.
---@param report lde.bloat.Report
---@param denominator number
local function interactiveBrowse(report, denominator)
	local raw = jit.os == "Windows" and require("readline.raw.windows") or require("readline.raw.posix")

	---@type table<number, boolean>
	local expanded = {}
	local window = VIEW_HEIGHT
	local cursor = 1
	local offset = 0

	---@return lde.bloat.UIRow[]
	local function visibleRows()
		local out = {} ---@type lde.bloat.UIRow[]
		for i, entry in ipairs(report.entries) do
			out[#out + 1] = { entryIndex = i, isEntry = true, text = entryRow(entry, i, denominator, expanded[i] or false) }
			if expanded[i] then
				for _, file in ipairs(entry.files) do
					out[#out + 1] = { entryIndex = i, isEntry = false, text = fileRow(entry, file, denominator) }
				end
			end
		end
		return out
	end

	local lastCount = 0
	---@param hidden number
	---@return string
	local function footerText(hidden)
		if hidden > 0 then
			return ansi.format("{gray}↑/↓ select · enter toggle · %d more below · q/esc quit{reset}", hidden)
		end
		return ansi.format("{gray}↑/↓ select · enter toggle · q/esc quit{reset}")
	end

	local function draw()
		local rows = visibleRows()
		local total = #rows
		if total == 0 then return end
		cursor = math.max(1, math.min(total, cursor))
		if cursor > offset + window then offset = cursor - window end
		if cursor <= offset then offset = cursor - 1 end

		local lines = {}
		for i = offset + 1, math.min(offset + window, total) do
			local row = rows[i]
			local text = row.text
			if i == cursor then
				text = ansi.colorize("underline", text)
			end
			lines[#lines + 1] = (i == cursor and ansi.colorize("green", "> ") or "  ") .. text
		end

		if lastCount > 0 then
			io.write("\r\x1b[" .. (lastCount + 1) .. "A\r")
		end
		for _, line in ipairs(lines) do
			io.write("\r\x1b[2K" .. line .. "\n")
		end
		for _ = #lines + 1, lastCount do
			io.write("\r\x1b[2K\n")
		end
		io.write("\r\x1b[2K" .. footerText(total - (offset + window)) .. "\n")
		io.flush()
		lastCount = #lines
	end

	---@param delta number
	local function move(delta)
		local total = #visibleRows()
		cursor = math.max(1, math.min(total, cursor + delta))
		draw()
	end

	local function toggle()
		local row = visibleRows()[cursor]
		if row and row.isEntry then
			expanded[row.entryIndex] = not expanded[row.entryIndex]
			draw()
		end
	end

	raw.enterRaw()
	io.write("\x1b[?25l")
	io.flush()
	draw()

	local done = false
	while not done do
		local ch = raw.readByte()
		if ch == nil or ch == "\x03" or ch == "q" or ch == "Q" then
			done = true
		elseif ch == "\r" or ch == "\n" then
			toggle()
		elseif ch == "\x1b" and not prompt.escSequencePending() then
			done = true -- bare Esc: quit
		elseif ch == "\x1b[A" then -- Windows returns the whole sequence at once
			move(-1)
		elseif ch == "\x1b[B" then
			move(1)
		elseif ch == "\x1b" then -- POSIX: escape byte, then [ then a letter
			local a = raw.readByte()
			if a == "[" then
				local b = raw.readByte()
				if b == "A" then move(-1)
				elseif b == "B" then move(1) end
			else
				done = true
			end
		elseif ch == "k" then
			move(-1)
		elseif ch == "j" then
			move(1)
		end
	end

	raw.exitRaw()
	io.write("\r")
	io.write("\x1b[?25h")
	io.flush()
end

---@param report lde.bloat.Report
---@param binaryPath string?
---@param binaryBytes number?
---@return string
local function jsonReport(report, binaryPath, binaryBytes)
	local payload = {
		name = report.rootName,
		totalBytes = report.totalBytes,
		luaFiles = report.luaFiles,
		luaBytes = report.luaBytes,
		nativeFiles = report.nativeFiles,
		nativeBytes = report.nativeBytes,
		entries = {},
	}
	if binaryBytes ~= nil then
		payload.binary = binaryPath
		payload.binaryBytes = binaryBytes
		payload.overheadBytes = binaryBytes - report.totalBytes
	end
	for _, entry in ipairs(report.entries) do
		local e = { name = entry.name, bytes = entry.bytes, isRoot = entry.isRoot, files = {} }
		for _, file in ipairs(entry.files) do
			e.files[#e.files + 1] = { name = file.name, kind = file.kind, bytes = file.bytes }
		end
		payload.entries[#payload.entries + 1] = e
	end
	return json.encode(payload)
end

---@param args clap.Args
local function bloat(args)
	-- --binary and --json both take an optional value: a bare flag resolves the
	-- default (the compile output / stdout), a value overrides it.
	local binaryPath = args:option("binary")
	if not binaryPath and args:flag("binary") then
		binaryPath = ""
	end

	local jsonPath = args:option("json")
	if not jsonPath and args:flag("json") then
		jsonPath = ""
	end

	local pkg, err = lde.Package.open()
	if not pkg then
		lde.error.raise(err)
	end ---@cast pkg -nil

	-- A bare `--json` pipes the report to stdout, so it must stay free of the
	-- build/install progress bars (which print to stdout); file mode keeps them.
	local report
	if jsonPath == "" then
		local wasVerbose = lde.isVerbose
		lde.isVerbose = false
		report = pkg:bloat()
		lde.isVerbose = wasVerbose
	else
		report = pkg:bloat()
	end

	local resolvedBinary
	local binaryBytes
	if binaryPath ~= nil then
		local candidate
		if binaryPath == "" then
			candidate = path.join(pkg:getDir(), pkg:getName())
			if jit.os == "Windows" then candidate = candidate .. ".exe" end
		else
			candidate = path.resolve(env.cwd(), binaryPath)
		end
		local stat = fs.stat(candidate)
		if not stat then
			lde.error.raise("Binary not found: " .. candidate, {
				hint = "Run `lde compile` first, or pass the path: lde bloat --binary <path>",
			})
		end ---@cast stat -nil
		resolvedBinary = candidate
		binaryBytes = tonumber(stat.size) or 0
	end

	if jsonPath ~= nil then
		local out = jsonReport(report, resolvedBinary, binaryBytes)
		if jsonPath == "" then
			io.write(out)
		else
			local target = path.resolve(env.cwd(), jsonPath)
			if not fs.write(target, out) then
				lde.error.raise("Failed to write report: " .. target)
			end
			ansi.printf("{green}Report written to %s", target)
		end
		return
	end

	if not renderPreamble(report, resolvedBinary, binaryBytes) then
		return
	end

	if prompt.interactive then
		interactiveBrowse(report, report.totalBytes)
	else
		renderRows(report, report.totalBytes)
	end
end

return bloat
