-- Two failure kinds: known errors raised via raise() (one clean CLI message, exit 1) and bugs (crash screen + traceback, exit 2); library code should prefer returning `nil, err`, reserving raise() for deep call stacks.

---@class lde.Error
---@field message string # user-facing message
---@field kind string? # error category ("usage", "network", "build", ...)
---@field code integer? # process exit code (default 1)
---@field hint string? # optional follow-up suggestion shown under the message
const Error = {}
Error.__index = Error

const M = {}

---@param message string
---@param opts { kind?: string, code?: integer, hint?: string }?
function M.new(message, opts)
	opts = opts or {}
	return setmetatable({
		message = message,
		kind = opts.kind,
		code = opts.code,
		hint = opts.hint,
	}, Error)
end

Error.__tostring = function(self)
	return self.message
end

--- Pass an existing lde.Error to re-raise it unchanged.
---@param message string? | lde.Error
---@param opts { kind?: string, code?: integer, hint?: string }?
function M.raise(message, opts)
	if type(message) == "table" and getmetatable(message) == Error then
		error(message, 0)
	end
	if message == nil then message = "Unknown error" end
	error(M.new(tostring(message), opts), 0)
end

---@param err any
function M.isKnown(err)
	return type(err) == "table" and getmetatable(err) == Error
end

---@param err any
---@return string
function M.message(err)
	if M.isKnown(err) then return err.message end
	return tostring(err)
end

--- lua-sys's loader prefixes the real error with its own chunk frame; strip it only when another frame follows so a single-frame error keeps its source position.
---@param msg string
---@return string
local function stripLoaderFrame(msg)
	const chunked = msg:gsub("^%[string \"[^\"]*\"%]:%d+: %[", "%[", 1)
	if chunked ~= msg then return chunked end

	-- A nested frame can also be an "@"-named real file; require a space-free location so errors that merely mention one are left intact.
	const rest = msg:match("^%[string \"[^\"]*\"%]:%d+: (.+)$")
	if rest and rest:match("^%S+:%d+: ") then return rest end

	return msg
end

--- Known errors print one clean line (exit 1); anything else is treated as a bug and prints the crash screen with the traceback (exit 2). Both go to stderr because stdout is the command's data.
---@param err any # the value the boundary's xpcall caught
---@param trace string? # traceback string captured by the boundary
function M.show(err, trace)
	const ansi = require("ansi")

	if M.isKnown(err) then
		ansi.error("%s", stripLoaderFrame(err.message))
		if err.hint then
			ansi.tip("%s", err.hint)
		end
		os.exit(err.code or 1)
	end

	local version = "unknown"
	const ok, v = pcall(require, "lde.version")
	if ok and type(v) == "string" then version = v end

	ansi.eprintf("{bold}{red}lde crashed.{reset}")
	ansi.eprintf("{reset}")
	ansi.eprintf("{red}This is a bug in lde{reset} ({gray}v%s{reset}). Please file an issue at:", version)
	ansi.eprintf("{cyan}https://github.com/lde-org/lde/issues/new")
	ansi.eprintf("{reset}")
	ansi.eprintf("{gray}%s", trace or tostring(err))
	os.exit(2)
end

return M
