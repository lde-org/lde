local ansi = require("ansi")
local clap = require("clap")
local fs = require("fs")
local path = require("path")
local json = require("json")
local semver = require("semver")

local lde = require("lde-core")
local luarocks = require("luarocks")
local prompt = require("lde.util.prompt")

--- Default cap on how many results are shown at once.
local DEFAULT_LIMIT = 10

---@class lde.search.Result
---@field name string
---@field description string?
---@field latest string?
---@field kind "registry"|"rocks"
---@field rank number? # computed sort rank

---@param query string # already lowercased
---@param s string?
---@return boolean
local function matches(query, s)
	return (s or ""):lower():find(query, 1, true) ~= nil
end

--- Sort rank: exact name match, then name prefix, then name substring, and
--- description-only matches last.
---@param query string
---@param name string
---@param description string?
---@return number
local function rank(query, name, description)
	local lname = name:lower()
	if lname == query then return 0 end
	if lname:sub(1, #query) == query then return 1 end
	if lname:find(query, 1, true) then return 2 end
	return 3 -- description match only
end

---@param versions table<string, string>?
---@return string? latest
local function latestVersion(versions)
	local latest ---@type string?
	for v in pairs(versions or {}) do
		if latest == nil or semver.compare(v, latest) > 0 then latest = v end
	end
	return latest
end

---@param query string
---@return lde.search.Result[]
local function searchRegistry(query)
	---@type lde.search.Result[]
	local results = {}
	local packagesDir = path.join(lde.global.getRegistryDir(), "packages")
	if fs.isdir(packagesDir) then
		for _, rel in ipairs(fs.scan(packagesDir, "**" .. path.separator .. "*.json")) do
			local content = fs.read(path.join(packagesDir, rel))
			local ok, portfile = pcall(json.decode, content or "")
			if ok and type(portfile) == "table" and type(portfile.name) == "string"
				and (matches(query, portfile.name) or matches(query, portfile.description)) then
				results[#results + 1] = {
					name = portfile.name,
					description = portfile.description,
					latest = latestVersion(portfile.versions),
					kind = "registry",
				}
			end
		end
	end
	return results
end

--- Package names matching the query from the cached luarocks manifest. Version
--- keys are excluded by requiring a package block to start with a version
--- block (`["name"] = { ["version"] = {`).
---@param query string
---@return lde.search.Result[]
local function searchRocks(query)
	local manifest = lde.util.getManifest()
	if not manifest then return {} end

	---@type lde.search.Result[]
	local results = {}
	for _, name in ipairs(lde.util.getManifestNames()) do
		if name:lower():find(query, 1, true) then
			results[#results + 1] = { name = name, kind = "rocks" }
		end
	end
	return results
end

--- Lazily fills in the latest version for a rock (parses its manifest block on
--- first use, so queries with thousands of matches stay cheap).
---@param r lde.search.Result
local function ensureLatest(r)
	if r.latest ~= nil then return end
	local manifest = lde.util.getManifest()
	if manifest then
		local best = luarocks.listBest(manifest, r.name)
		r.latest = best[1] and best[1].version or nil
	end
end

---@param r lde.search.Result
---@return string
local function formatRow(r)
	-- Rocks get a rock emoji before the name (a plain "R" when the terminal
	-- can't render emoji); the luarocks manifest has no descriptions, so rock
	-- rows are just the marker + name + version.
	local prefix = ""
	if r.kind == "rocks" then
		prefix = ansi.supportsEmoji() and "🪨 " or "R "
	end
	local desc = r.description and ("  " .. r.description) or ""
	local ver = r.latest and (" (" .. r.latest .. ")") or ""
	return ansi.format("{green}%s%s{reset}%s{gray}%s{reset}", prefix, r.name, desc, ver)
end

--- The command verb the selector's Enter action runs.
---@param inPackage boolean
---@return string
local function actionVerb(inPackage)
	return inPackage and "lde add" or "lde install"
end

--- Run the action for a picked result in-process.
---@param r lde.search.Result
---@param inPackage boolean
local function runAction(r, inPackage)
	local name = r.kind == "rocks" and ("rocks:" .. r.name) or r.name
	local command = inPackage and "lde.commands.add" or "lde.commands.install"
	require(command)(clap.parse({ name }))
end

--- Interactive selector: ↑/↓ (or j/k) move a cursor through all results
--- (scrolling the window to follow it), Enter runs the add/install action for
--- the selection, q/Esc/EOF cancels.
---@param results lde.search.Result[]
---@param limit number
---@param inPackage boolean
---@return lde.search.Result? # nil when cancelled
local function selectResult(results, limit, inPackage)
	local raw = jit.os == "Windows" and require("readline.raw.windows") or require("readline.raw.posix")
	local total = #results
	local window = math.min(limit, total)
	local cursor = 1 -- 1-based result index
	local offset = 0 -- 0-based index of the first visible result

	local function rowText(r, isSelected)
		local marker = isSelected and "{green}>{reset} " or "  "
		local text = formatRow(r)
		if isSelected then text = ansi.format("{underline}%s{reset}", text) end
		return ansi.format(marker .. "%s", text)
	end

	local function visible()
		local out = {}
		for i = offset + 1, offset + window do
			ensureLatest(results[i])
			out[#out + 1] = rowText(results[i], i == cursor)
		end
		return out
	end

	local function footer()
		local hidden = total - (offset + window)
		local verb = actionVerb(inPackage)
		if hidden > 0 then
			return ansi.format("{gray}Enter to {reset}{yellow}%s{reset}{gray} · %d more below · ↑/↓ select · q/esc cancel{reset}", verb, hidden)
		end
		return ansi.format("{gray}Enter to {reset}{yellow}%s{reset}{gray} · ↑/↓ select · q/esc cancel{reset}", verb)
	end

	local lastCount = 0
	---@param lines string[]
	local function draw(lines)
		if lastCount > 0 then
			io.write("\r\x1b[" .. (lastCount + 1) .. "A\r")
		end
		for _, line in ipairs(lines) do
			io.write("\r\x1b[2K" .. line .. "\n")
		end
		for i = #lines + 1, lastCount do
			io.write("\r\x1b[2K\n")
		end
		io.write("\r\x1b[2K" .. footer() .. "\n")
		io.flush()
		lastCount = #lines
	end

	---@param delta number
	local function move(delta)
		cursor = math.max(1, math.min(total, cursor + delta))
		if cursor > offset + window then offset = cursor - window end
		if cursor <= offset then offset = cursor - 1 end
		draw(visible())
	end

	raw.enterRaw()
	io.write("\x1b[?25l")
	io.flush()

	draw(visible())

	local done = false
	local picked ---@type lde.search.Result?
	while not done do
		local ch = raw.readByte()
		if ch == nil or ch == "\x03" or ch == "q" or ch == "Q" then
			done = true
		elseif ch == "\r" or ch == "\n" then
			picked = results[cursor]
			done = true
		elseif ch == "\x1b" and not prompt.escSequencePending() then
			-- bare Esc with nothing more coming: cancel
			done = true
		elseif ch == "\x1b[A" then -- Windows returns the whole sequence at once
			move(-1)
		elseif ch == "\x1b[B" then
			move(1)
		elseif ch == "\x1b" then -- POSIX: escape byte, then [, then a letter
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
	-- Raw mode disables OPOST, so the draw's trailing \n moved the cursor down
	-- without returning it to column 0. The cursor is already on the blank line
	-- below the footer; a plain \r parks it at column 0 there without adding an
	-- extra empty line before the shell prompt (or the action's output).
	io.write("\r")
	io.write("\x1b[?25h")
	io.flush()
	return picked
end

---@param args clap.Args
local function search(args)
	local showAll = args:flag("all")
	args:flag("rocks") -- accepted for compatibility; rocks are included by default now
	local rawQuery = args:pop()
	if not rawQuery then
		lde.error.raise("Usage: lde search <query> [--all]", {
			hint = "Searches the lde registry and luarocks; rocks:<query> searches luarocks only.",
		})
	end ---@cast rawQuery -nil

	-- `lde search rocks:<query>` searches luarocks only.
	local rocksOnly = false
	local query = rawQuery
	if query:sub(1, 6) == "rocks:" then
		rocksOnly = true
		query = query:sub(7)
	end
	if query == "" then
		lde.error.raise("Usage: lde search <query> [--all]", {
			hint = "Searches the lde registry and luarocks; rocks:<query> searches luarocks only.",
		})
	end ---@cast query -nil
	query = query:lower()

	---@type lde.search.Result[]
	local results = {}
	if not rocksOnly then
		local regOk = pcall(lde.global.syncRegistry)
		if regOk then
			for _, r in ipairs(searchRegistry(query)) do results[#results + 1] = r end
		end
	end
	-- luarocks matches are always included (rocks:<query> searches them only).
	for _, r in ipairs(searchRocks(query)) do results[#results + 1] = r end

	-- Sort: exact name > name prefix > name substring > description-only,
	-- with lde registry packages preferred over luarocks within the same rank.
	for _, r in ipairs(results) do r.rank = rank(query, r.name, r.description) end
	table.sort(results, function(a, b)
		if a.rank ~= b.rank then return a.rank < b.rank end
		if a.kind ~= b.kind then return a.kind == "registry" end
		return a.name < b.name
	end)

	local total = #results
	if total == 0 then
		ansi.note("No packages found matching '{yellow}%s{reset}'.", query)
		ansi.tip("Browse the luarocks registry: https://luarocks.org/search?q=%s", query)
		return
	end

	-- "Found N packages matching 'q':" — N green, query yellow, colon gray.
	ansi.printf("Found {green}%d{reset} package%s matching {yellow}'%s'{reset}{gray}:{reset}",
		total, total == 1 and "" or "s", query)

	local inPackage = lde.Package.open() ~= nil
	local limit = showAll and total or DEFAULT_LIMIT

	if prompt.interactive then
		local picked = selectResult(results, limit, inPackage)
		if picked then
			runAction(picked, inPackage)
		end
		return
	end

	-- Non-interactive (pipes, CI): show the first `limit` results and say how
	-- many were left out.
	local shown = 0
	for _, r in ipairs(results) do
		if shown >= limit then break end
		ensureLatest(r)
		print(formatRow(r))
		shown = shown + 1
	end
	if total > limit then
		print("  " .. ansi.format("{gray}… and %d more (run in a terminal to browse and select){reset}", total - limit))
	end
end

return search
