local ansi = require("ansi")
local fs = require("fs")
local path = require("path")
local process = require("process")

local lpm = require("lpm-core")

---@param args clap.Args
local function toolUninstall(args)
	local toolName = args:pop()
	if not toolName then
		ansi.printf("{red}Usage: lpm uninstall <name>")
		return
	end

	local toolsDir = lpm.global.getToolsDir()

	-- Try the platform-specific wrapper path first, then the bare name
	local candidates
	if process.platform == "win32" then
		candidates = {
			path.join(toolsDir, toolName .. ".cmd"),
			path.join(toolsDir, toolName)
		}
	else
		candidates = {
			path.join(toolsDir, toolName)
		}
	end

	local removed = false
	for _, wrapperPath in ipairs(candidates) do
		if fs.exists(wrapperPath) then
			if not fs.delete(wrapperPath) then
				error("Failed to remove wrapper: " .. wrapperPath)
			end
			ansi.printf("{green}Uninstalled tool '%s'", toolName)
			removed = true
			break
		end
	end

	if not removed then
		ansi.printf("{yellow}Tool '%s' is not installed.", toolName)
	end
end

return toolUninstall
