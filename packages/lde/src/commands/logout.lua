const ansi = require("ansi")

const auth = require("lde.github.auth")

local function logout()
	const session = auth.load()
	auth.clear()

	if session then
		ansi.printf("{green}Logged out of GitHub.")
	else
		ansi.printf("Not logged in to GitHub.")
	end
end

return logout
