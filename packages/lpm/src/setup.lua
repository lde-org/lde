local ansi = require("ansi")
local fs = require("fs")
local path = require("path")
local process = require("process")

local lpm = require("lpm-core")

---@param lpmDir string
---@param toolsDir string
local function updatePath(lpmDir, toolsDir)
	if process.platform == "win32" then
		-- Read current user PATH, append missing dirs, write back via PowerShell
		local getCmd = '[Environment]::GetEnvironmentVariable("Path","User")'
		local ok, currentPath = process.exec("powershell", { "-NoProfile", "-Command", getCmd })
		if not ok then
			ansi.printf("{red}Failed to read user PATH from registry")
			return
		end
		currentPath = currentPath and currentPath:gsub("%s+$", "") or ""

		local dirsToAdd = {}
		if not currentPath:find(lpmDir, 1, true) then
			dirsToAdd[#dirsToAdd + 1] = lpmDir
		end
		if not currentPath:find(toolsDir, 1, true) then
			dirsToAdd[#dirsToAdd + 1] = toolsDir
		end

		if #dirsToAdd == 0 then
			ansi.printf("{green}PATH is already up to date.")
			return
		end

		local sep = (currentPath ~= "" and not currentPath:match(";$")) and ";" or ""
		local newPath = currentPath .. sep .. table.concat(dirsToAdd, ";")
		local setCmd = string.format('[Environment]::SetEnvironmentVariable("Path","%s","User")', newPath)
		local setOk, setErr = process.spawn("powershell", { "-NoProfile", "-Command", setCmd })
		if not setOk then
			ansi.printf("{red}Failed to update PATH: %s", setErr or "unknown error")
			return
		end
		for _, d in ipairs(dirsToAdd) do
			ansi.printf("{green}Added to PATH: %s", d)
		end
		ansi.printf("{yellow}Restart your terminal for the change to take effect.")
	else
		-- Unix: patch the first shell rc file that already mentions .lpm, or
		-- the first that exists among the standard candidates.
		local home = os.getenv("HOME") or ""
		local rcFiles = {
			home .. "/.zshrc",
			home .. "/.zprofile",
			home .. "/.bashrc",
			home .. "/.bash_profile",
			home .. "/.profile"
		}

		local pathLine = 'export PATH="$HOME/.lpm:$HOME/.lpm/tools:$PATH"'

		-- Find a file that already has an lpm PATH entry and needs updating,
		-- or the first rc file that exists (to append to).
		local target = nil
		for _, rc in ipairs(rcFiles) do
			if fs.exists(rc) then
				local content = fs.read(rc) or ""
				if content:find("%.lpm", 1, true) then
					-- Already has some lpm entry — check if tools is missing
					if not content:find("%.lpm/tools", 1, true) then
						-- Replace the existing lpm PATH line with the full one
						local updated = content:gsub('export PATH="[^"]*%.lpm[^"]*"', pathLine)
						if updated == content then
							-- Line format didn't match the pattern; just append
							updated = content .. "\n" .. pathLine .. "\n"
						end
						fs.write(rc, updated)
						ansi.printf("{green}Updated PATH in %s", rc)
					else
						ansi.printf("{green}PATH is already up to date in %s", rc)
					end
					return
				end
				if not target then target = rc end
			end
		end

		-- No file had an lpm entry yet — append to the first existing rc
		if target then
			local content = fs.read(target) or ""
			fs.write(target, content .. "\n# Added by lpm\n" .. pathLine .. "\n")
			ansi.printf("{green}Added PATH entry to %s", target)
		else
			ansi.printf("{yellow}Could not find a shell rc file to update.")
			ansi.printf("{white}Add this line manually:  %s", pathLine)
		end
		ansi.printf("{yellow}Restart your shell or run: source <rc-file>")
	end
end

---@param lpmDir string
local function installLpx(lpmDir)
	if process.platform == "win32" then
		local lpxPath = path.join(lpmDir, "lpx.cmd")
		fs.write(lpxPath, "@echo off\r\nlpm x %*\r\n")
		ansi.printf("{green}Installed lpx -> %s", lpxPath)
	else
		local lpxPath = path.join(lpmDir, "lpx")
		fs.write(lpxPath, "#!/bin/sh\nexec lpm x \"$@\"\n")
		process.spawn("chmod", { "+x", lpxPath })
		ansi.printf("{green}Installed lpx -> %s", lpxPath)
	end
end

local function setup()
	local lpmDir = lpm.global.getDir()
	local toolsDir = lpm.global.getToolsDir()

	updatePath(lpmDir, toolsDir)
	installLpx(lpmDir)
end

return setup
