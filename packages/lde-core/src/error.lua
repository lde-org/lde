-- lde-core/src/error.lua
--
-- lde's error convention. Two kinds of failure exist:
--
--   * Known errors — problems the user can act on (bad flags, missing files,
--     network failures, unresolvable deps). Raised with lde.error.raise(),
--     rendered by the CLI boundary as a single clean message, exit code 1.
--   * Bugs — anything else that escapes to the CLI boundary. Rendered as the
--     "lde crashed" screen with a full traceback, exit code 2.
--
-- Library code should prefer returning `nil, err` (idiomatic Lua) and reserve
-- raise() for deep call stacks where threading the error out isn't practical.
--
-- __tostring returns the message, so existing `tostring(err)` and `".. " .. err`
-- catchers keep working while error() sites migrate to raise().

---@class lde.Error
---@field message string # user-facing message
---@field kind string? # error category ("usage", "network", "build", ...)
---@field code integer? # process exit code (default 1)
---@field hint string? # optional follow-up suggestion shown under the message
local Error = {}
Error.__index = Error

local M = {}

---@param message string
---@param opts { kind?: string, code?: integer, hint?: string }?
---@return lde.Error
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

--- Raise a known, user-facing error. The CLI boundary renders it cleanly
--- (never a traceback). Pass an existing lde.Error to re-raise it unchanged.
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
---@return boolean
function M.isKnown(err)
	return type(err) == "table" and getmetatable(err) == Error
end

--- Safe unwrap of any error value to a user-facing string.
---@param err any
---@return string
function M.message(err)
	if M.isKnown(err) then return err.message end
	return tostring(err)
end

--- Renders the boundary's catch and exits. Known errors print one clean line
--- (exit 1); anything else is treated as a bug in lde and prints the crash
--- screen with the traceback (exit 2).
---@param err any # the value the boundary's xpcall caught
---@param trace string? # traceback string captured by the boundary
function M.show(err, trace)
	local ansi = require("ansi")

	if M.isKnown(err) then
		ansi.printf("{red}error{gray}:{reset} %s", err.message)
		if err.hint then
			ansi.printf("{yellow}Hint: %s", err.hint)
		end
		os.exit(err.code or 1)
	end

	-- Unexpected: an actual bug in lde (or an error() site that hasn't been
	-- migrated to raise() yet).
	local version = "unknown"
	local ok, v = pcall(require, "lde.version")
	if ok and type(v) == "string" then version = v end

	ansi.printf("{bold}{red}lde crashed.{reset}")
	ansi.printf("{reset}")
	ansi.printf("{red}This is a bug in lde{reset} ({gray}v%s{reset}). Please file an issue at:", version)
	ansi.printf("{cyan}https://github.com/lde-org/lde/issues/new")
	ansi.printf("{reset}")
	ansi.printf("{gray}%s", trace or tostring(err))
	os.exit(2)
end

return M
