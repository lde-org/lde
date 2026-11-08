const ansi = require("ansi")

const lde = require("lde-core")
const auth = require("lde.github.auth")
const browser = require("lde.util.browser")

local function login()
	const session, err = auth.login({
		onCode = function(device)
			---@cast device lde.github.AuthDeviceCode
			-- Show the code before launching the browser: an opener that waits
			-- for the browser to exit must not hide the code or block polling.
			ansi.printf("Open {cyan}%s{reset} and enter code {bold}%s{reset}", device.verificationUri, device.userCode)
			browser.open(device.verificationUri)
		end,
	})

	if not session then
		lde.error.raise(err or "GitHub login failed")
	end ---@cast session -nil

	ansi.printf("{green}Logged in to GitHub as {bold}%s{reset}.", session.login or "unknown user")
end

return login
