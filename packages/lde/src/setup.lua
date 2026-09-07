local ansi = require("ansi")
local fs = require("fs")
local path = require("path")
local process = require("process")

local lde = require("lde-core")

---@param ldeDir string
---@param toolsDir string
local function updatePath(ldeDir, toolsDir)
	if jit.os == "Windows" then
		-- Read current user PATH, append missing dirs, write back via PowerShell
		local getCmd = '[Environment]::GetEnvironmentVariable("Path","User")'
		local code, stdout, stderr = process.exec("powershell", { "-NoProfile", "-Command", getCmd })
		if code ~= 0 then
			ansi.printf("{red}Failed to read user PATH from registry")
			return
		end
		currentPath = stdout and stdout:gsub("%s+$", "") or ""

		local dirsToAdd = {}
		if not currentPath:find(ldeDir, 1, true) then
			dirsToAdd[#dirsToAdd + 1] = ldeDir
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
		local setChild, setErr = process.spawn("powershell", { "-NoProfile", "-Command", setCmd })
		if not setChild then
			ansi.printf("{red}Failed to update PATH: %s", setErr or "unknown error")
			return
		end
		setChild:wait()
		for _, d in ipairs(dirsToAdd) do
			ansi.printf("{green}Added to PATH: %s", d)
		end
		ansi.printf("{yellow}Restart your terminal for the change to take effect.")
	else
		-- Unix: patch the first shell rc file that already mentions the lde
		-- home, or the first that exists among the standard candidates.
		local home = os.getenv("HOME") or ""
		local ldeHome = os.getenv("LDE_HOME")
		-- When LDE_HOME is set, tools live there rather than under ~/.lde, so
		-- the PATH entry references $LDE_HOME (dynamic, like $HOME below) and
		-- rc detection keys on the LDE_HOME marker — repeated setups must not
		-- append duplicate lines.
		local hasLdeHome = ldeHome ~= nil and ldeHome ~= ""
		local homeRef = hasLdeHome and "$LDE_HOME" or "$HOME/.lde"
		local marker = hasLdeHome and "LDE_HOME" or ".lde"
		-- gsub takes a pattern: the dot in ".lde" must be escaped there.
		local patternMarker = hasLdeHome and "LDE_HOME" or "%.lde"
		local pathLine = 'export PATH="' .. homeRef .. ':' .. homeRef .. '/tools:$PATH"'

		local defaultRc = jit.os == "OSX" and (home .. "/.zshrc") or (home .. "/.profile")

		local rcFiles = {
			home .. "/.zshrc",
			home .. "/.zprofile",
			home .. "/.bashrc",
			home .. "/.bash_profile",
			home .. "/.profile"
		}

		-- Find a file that already has an lde PATH entry and needs updating,
		-- or the first rc file that exists (to append to).
		local target = nil
		for _, rc in ipairs(rcFiles) do
			if fs.exists(rc) then
				local content = fs.read(rc) or ""
				if content:find(marker, 1, true) then
					-- Already has some lde entry, check if tools is missing
					if not content:find(marker .. "/tools", 1, true) then
						-- Replace the existing lde PATH line with the full one
						local updated = content:gsub('export PATH="[^"]*' .. patternMarker .. '[^"]*"', pathLine)
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

		-- No file had an lde entry yet, append to the first existing rc (or create the default)
		target = target or defaultRc
		local content = fs.read(target) or ""
		fs.write(target, content .. "\n# Added by lde\n" .. pathLine .. "\n")
		ansi.printf("{green}Added PATH entry to %s", target)

		ansi.printf("{yellow}Restart your shell or run: source <rc-file>")
	end
end

---@param ldeDir string
local function installBinaries(ldeDir)
	if jit.os == "Windows" then
		local ldxPath = path.join(ldeDir, "ldx.cmd")
		fs.write(ldxPath, "@echo off\r\nlde x %*\r\n")
		ansi.printf("{green}Installed ldx -> %s", ldxPath)
	else
		local ldxPath = path.join(ldeDir, "ldx")
		fs.write(ldxPath, "#!/bin/sh\nexec lde x \"$@\"\n")
		process.spawn("chmod", { "+x", ldxPath }):wait()
		ansi.printf("{green}Installed ldx -> %s", ldxPath)
	end
end

local function setup()
	local ldeDir = lde.global.getDir()
	local toolsDir = lde.global.getToolsDir()

	updatePath(ldeDir, toolsDir)
	-- A fresh LDE_HOME (or ~/.lde) may not exist yet; ldx is written into it.
	fs.mkdirAll(ldeDir)
	installBinaries(ldeDir)
end

return setup
