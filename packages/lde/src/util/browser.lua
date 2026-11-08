-- Opens a URL in the user's default browser, without a shell.

const process = require("process")

local browser = {}

---@class lde.util.BrowserChild
---@field wait fun(self: lde.util.BrowserChild): number?

---@class lde.util.BrowserOpts
---@field os string? # jit.os override for tests
---@field spawn fun(name: string, args: string[], opts: table?): lde.util.BrowserChild? # process.spawn override for tests

---@param url string
---@param opts lde.util.BrowserOpts?
---@return boolean opened
function browser.open(url, opts)
	opts = opts or {}
	const osName = opts.os or jit.os
	const spawn = opts.spawn or process.spawn

	---@type { name: string, args: string[] }[]
	local candidates
	if osName == "Windows" then
		candidates = {
			{ name = "cmd", args = { "/c", "start", "", url } },
		}
	elseif osName == "OSX" then
		candidates = {
			{ name = "open", args = { url } },
		}
	else
		-- Linux, the BSDs, and WSL. The first command that exists and exits
		-- successfully wins; a missing opener exits non-zero and falls through.
		candidates = {
			{ name = "xdg-open", args = { url } },
			{ name = "gio", args = { "open", url } },
			{ name = "sensible-browser", args = { url } },
			{ name = "x-www-browser", args = { url } },
			{ name = "wslview", args = { url } },
			{ name = "cmd.exe", args = { "/c", "start", "", url } },
		}
	end

	for _, candidate in ipairs(candidates) do
		const child = spawn(candidate.name, candidate.args, { stdout = "null", stderr = "null" })
		if child then
			const code = child:wait()
			if code == 0 then return true end
		end
	end
	return false
end

return browser
