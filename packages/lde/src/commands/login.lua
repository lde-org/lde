const ansi = require("ansi")

const lde = require("lde-core")
const auth = require("lde.github.auth")

local function login()
	const session, err = auth.login({
		onCode = function(device)
			---@cast device lde.github.AuthDeviceCode
			ansi.printf("Open {cyan}%s{reset} and enter code {bold}%s{reset}", device.verificationUri, device.userCode)
		end,
	})

	if not session then
		lde.error.raise(err or "GitHub login failed")
	end ---@cast session -nil

	ansi.printf("{green}Logged in to GitHub as {bold}%s{reset}.", session.login or "unknown user")
	if session.twoFactor ~= true then
		ansi.printf("{yellow}Two-factor authentication is not enabled on this GitHub account. Publishing is disabled until it is.")
	end
end

return login
