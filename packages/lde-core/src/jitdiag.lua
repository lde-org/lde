-- lde-core/src/jitdiag.lua
--
-- JIT diagnostics for `lde run --jit`: LuaJIT -jv-style trace reporting.
-- Hooks jit.attach in a guest state and reports trace aborts — code that
-- could not be JIT-compiled — with a source location and the compiler's
-- reason (e.g. "NYI: bytecode FNEW"), plus a summary of compiled vs aborted
-- traces. This is a trace-level diagnostic: it fires on every trace event,
-- so it is opt-in and deliberately separate from the sampling --profile.

local ansi = require("ansi")
local path = require("path")
local env = require("env")
local highlight = require("ansi.highlight")

local jitdiag = {}

-- Trace compiler error codes (TraceError enum), in order, from the bundled
-- LuaJIT fork's src/lj_traceerr.h. The attach callback passes the code as an
-- integer; %s/%d placeholders are filled from the event's errinfo.
---@type table<integer, string>
local TRACE_ERRORS = {
	[0]  = "error thrown or hook called during recording",
	[1]  = "trace too short",
	[2]  = "trace too long",
	[3]  = "trace too deep",
	[4]  = "too many snapshots",
	[5]  = "blacklisted",
	[6]  = "retry recording",
	[7]  = "NYI: bytecode %s",
	[8]  = "leaving loop in root trace",
	[9]  = "inner loop in root trace",
	[10] = "loop unroll limit reached",
	[11] = "bad argument type",
	[12] = "JIT compilation disabled for function",
	[13] = "call unroll limit reached",
	[14] = "down-recursion, restarting",
	[15] = "NYI: unsupported variant of FastFunc %s",
	[16] = "NYI: return to lower frame",
	[17] = "store with nil or NaN key",
	[18] = "missing metamethod",
	[19] = "looping index lookup",
	[20] = "NYI: mixed sparse/dense table",
	[21] = "symbol not in cache",
	[22] = "NYI: unsupported C type conversion",
	[23] = "NYI: unsupported C function type",
	[24] = "guard would always fail",
	[25] = "too many PHIs",
	[26] = "persistent type instability",
	[27] = "failed to allocate mcode memory",
	[28] = "machine code too long",
	[29] = "hit mcode limit (retrying)",
	[30] = "too many spill slots",
	[31] = "inconsistent register allocation",
	[32] = "NYI: cannot assemble IR instruction %d",
	[33] = "NYI: PHI shuffling too complex",
	[34] = "NYI: register coalescing too complex",
}

-- Bytecode opcode names, in order, from the fork's src/lj_bc.h. The NYIBC
-- abort's errinfo is the opcode number ("NYI: bytecode <opcode>"), which we
-- decode to a name here.
---@type string[]
local BC_NAMES = {
	"ISLT", "ISGE", "ISLE", "ISGT", "ISEQV", "ISNEV", "ISEQS", "ISNES",
	"ISEQN", "ISNEN", "ISEQP", "ISNEP", "ISTC", "ISFC", "IST", "ISF",
	"ISTYPE", "ISNUM", "MOV", "NOT", "UNM", "LEN", "ADDVN", "SUBVN",
	"MULVN", "DIVVN", "MODVN", "ADDNV", "SUBNV", "MULNV", "DIVNV", "MODNV",
	"ADDVV", "SUBVV", "MULVV", "DIVVV", "MODVV", "POW", "CAT", "KSTR",
	"KCDATA", "KSHORT", "KNUM", "KPRI", "KNIL", "UGET", "USETV", "USETS",
	"USETN", "USETP", "UCLO", "FNEW", "TNEW", "TDUP", "GGET", "GSET",
	"TGETV", "TGETS", "TGETB", "TGETR", "TSETV", "TSETS", "TSETB", "TSETM",
	"TSETR", "CALLM", "CALL", "CALLMT", "CALLT", "ITERC", "ITERN", "VARG",
	"ISNEXT", "RETM", "RET", "FORI", "JFORI", "FORL", "IFORL", "JFORL",
	"ITERL", "IITERL", "JITERL", "LOOP", "ILOOP", "JLOOP", "JMP", "BNOT",
	"BAND", "BOR", "BXOR", "BSHL", "BSHR", "BSAR", "FUNCF", "IFUNCF",
	"JFUNCF", "FUNCV", "IFUNCV", "JFUNCV", "FUNCC", "FUNCCW",
}

--- Decode an abort reason code + errinfo into a human message.
---@param code integer
---@param errinfo string?
---@return string
local function formatReason(code, errinfo)
	local template = TRACE_ERRORS[code]
	if not template then
		return "unknown trace error " .. tostring(code)
	end
	if code == 7 then -- NYIBC: errinfo is the opcode number; report "FNEW is NYI"
		local op = tonumber(errinfo or "")
		local name = op and BC_NAMES[op + 1] or errinfo or "?"
		return name .. " is NYI"
	end
	if template:find("%%") then
		return string.format(template, errinfo or "?")
	end
	return template
end

-- Installed per guest state. The guest callback forwards (event, info) to the
-- driver; the driver formats with ansi and tallies.
---@class lde.jitdiag.Session
---@field compiled integer
---@field aborted integer
---@field sites table<string, { count: integer, reason: string, file: string, line: integer }>
local Session = {}
Session.__index = Session

---@return lde.jitdiag.Session
local function newSession()
	return setmetatable({
		compiled = 0,
		aborted = 0,
		sites = {},
	}, Session)
end

---@param file string
---@return string # path relativized against cwd when possible
local function displayPath(file)
	file = file:gsub("^@", "")
	local cwd = env.cwd()
	if cwd and file:sub(1, #cwd + 1) == cwd .. "/" then
		return file:sub(#cwd + 2)
	end
	return file
end

--- Split source text into lines (dropping the empty entry left by a final
--- newline). gmatch-based splitting miscounts blank lines.
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
	return lines
end

---@param line string
---@return string
local function expandTabs(line)
	return (line:gsub("\t", "    "))
end

-- Guest-side bootstrap: installs jit.attach and forwards events to the
-- driver. NB: the config vararg must not shadow the global `jit`.
local BOOTSTRAP = [==[
local diag = ...
local util = require("jit.util")

jit.attach(function(event, trace, func, pos, reason, errinfo)
	if event == "start" then
		diag.count("start")
		return
	end
	if event == "stop" then
		diag.count("stop")
		return
	end
	if event ~= "abort" then return end

	-- The exact aborting location: funcinfo(func, pc) reports the function's
	-- source plus the line of the bytecode position — the same trick jit.v
	-- uses.
	local file, line = "?", -1
	local fi = util.funcinfo(func, pos)
	if type(fi) == "table" and fi.loc then
		local locFile, locLine = tostring(fi.loc):match("^(.-):(%d+)$")
		if locFile then
			file, line = locFile, tonumber(locLine) or -1
		else
			file = tostring(fi.loc)
		end
	end
	diag.abort({
		trace = trace,
		file = file,
		line = line,
		reason = reason,
		errinfo = tostring(errinfo),
	})
end, "trace")
]==]

-- Handles for reporting after a run: state -> session. The state is a lua-sys
-- object; keys are weak so closed states drop out.
---@type table<lua.State, lde.jitdiag.Session>
local sessions = setmetatable({}, { __mode = "k" })

--- Install trace diagnostics into a guest state. The guest forwards every
--- trace event; aborts print live (deduped per site) and are tallied for the
--- end-of-run report.
---@param state lua.State
---@param opts { cwd: string? }?
function jitdiag.install(state, opts)
	opts = opts or {}
	local session = newSession()

	-- Called from the guest on every trace event.
	---@param event string
	local function onCount(event)
		if event == "stop" then session.compiled = session.compiled + 1 end
	end

	---@param info { trace: integer, file: string, line: integer, reason: integer, errinfo: string }
	local function onAbort(info)
		session.aborted = session.aborted + 1
		local reason = formatReason(info.reason, info.errinfo)
		local file = displayPath(info.file)
		local key = file .. ":" .. tostring(info.line) .. " " .. reason
		local site = session.sites[key]
		if site then
			site.count = site.count + 1
			return
		end
		site = {
			count = 1,
			reason = reason,
			file = file,
			line = info.line,
		}
		session.sites[key] = site
		-- First occurrence of this site prints live as a warning.
		ansi.printf("{yellow}jit{reset}: {red}aborted{reset} at %s - %s",
			file .. ":" .. site.line, ansi.colorize("yellow", reason))
	end

	local boot = state:load(BOOTSTRAP, "@lde-jitdiag")
	local ok, err = boot:pcall({
		count = onCount,
		abort = onAbort,
	})
	if not ok then
		-- jit.attach unavailable (JIT-disabled build): diagnostics are a no-op.
		return nil, err
	end

	sessions[state] = session
	return session
end

--- The session for a state (nil when diagnostics were not installed).
---@param state lua.State
---@return lde.jitdiag.Session?
function jitdiag.sessionFor(state)
	return sessions[state]
end

---@param session lde.jitdiag.Session
---@param cwd string?
function jitdiag.report(session, cwd)
	local sites = {}
	for _key, site in pairs(session.sites) do
		sites[#sites + 1] = site
	end
	table.sort(sites, function(a, b) return a.count > b.count end)

	ansi.printf("{yellow}jit{reset}: {gray}%d traces compiled, %d aborted (%d site%s){reset}",
		session.compiled, session.aborted, #sites, #sites == 1 and "" or "s")
	for _, site in ipairs(sites) do
		-- Bun-style block: highlighted snippet with an underline under the
		-- incident line and the reason beside it. Fall back to a one-liner
		-- when the source file can't be read.
		local rendered = false
		if cwd and site.line > 0 then
			local f = path.isAbsolute(site.file) and site.file or path.join(cwd, site.file)
			local src = require("fs").read(f)
			if src then
				rendered = true
				local lines = splitLines(src)
				local startLine = math.max(1, site.line - 1)
				local endLine = math.min(#lines, site.line + 1)
				local width = #tostring(endLine)
				local function gutter(ln)
					local num = string.format("%" .. width .. "d | ", ln)
					return ansi.colorize("gray", num)
				end
				-- Caret directly under the incident line (mid-window), with the
				-- remaining context after it — same layout as run errors.
				for ln = startLine, site.line do
					print(gutter(ln) .. highlight(expandTabs(lines[ln])))
				end
				local content = expandTabs(lines[site.line] or "")
				local first = content:find("%S") or 1
				local len = math.max(1, #content - first + 1)
				print(ansi.colorize("gray", string.rep(" ", width) .. " | ") .. string.rep(" ", first - 1)
					.. ansi.format("{yellow}{bold}%s{reset}", string.rep("^", len))
					.. " " .. ansi.colorize("yellow", site.reason))
				for ln = site.line + 1, endLine do
					print(gutter(ln) .. highlight(expandTabs(lines[ln])))
				end
				ansi.printf("  {gray}%s:%d{reset} {yellow}%d×{reset}", site.file, site.line, site.count)
			end
		end
		if not rendered then
			ansi.printf("  {gray}%s:%d - %s{reset} {yellow}%d×{reset}",
				site.file, site.line, site.reason, site.count)
		end
	end
end

return jitdiag
