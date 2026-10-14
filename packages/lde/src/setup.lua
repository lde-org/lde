const ansi = require("ansi")
const fs = require("fs")
const path = require("path")
const process = require("process")

const lde = require("lde-core")

---@param ldeDir string
---@param toolsDir string
local function updatePath(ldeDir, toolsDir)
	if jit.os == "Windows" then
		const getCmd = '[Environment]::GetEnvironmentVariable("Path","User")'
		const code, stdout =  process.exec("powershell", { "-NoProfile", "-Command", getCmd })
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

		const sep = (currentPath ~= "" and not currentPath:match(";$")) and ";" or ""
		const newPath = currentPath .. sep .. table.concat(dirsToAdd, ";")
		const setCmd = string.format('[Environment]::SetEnvironmentVariable("Path","%s","User")', newPath)
		const setChild, setErr = process.spawn("powershell", { "-NoProfile", "-Command", setCmd })
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
		-- Unix: patch the first rc file that mentions the lde home, or the first that exists.
		local home = os.getenv("HOME") or ""
		const ldeHome = os.getenv("LDE_HOME")
		-- With LDE_HOME set, tools live there, so the entry references $LDE_HOME and rc detection keys on the LDE_HOME marker; repeated setups must not append duplicates.
		const hasLdeHome = ldeHome ~= nil and ldeHome ~= ""
		const homeRef = hasLdeHome ? "$LDE_HOME" : "$HOME/.lde"
		local marker = hasLdeHome ? "LDE_HOME" : ".lde"
		-- gsub takes a pattern: the dot in ".lde" must be escaped there.
		const patternMarker = hasLdeHome ? "LDE_HOME" : "%.lde"
		const pathLine = 'export PATH="' .. homeRef .. ':' .. homeRef .. '/tools:$PATH"'

		const defaultRc = jit.os == "OSX" and (home .. "/.zshrc") or (home .. "/.profile")

		const rcFiles = {
			home .. "/.zshrc",
			home .. "/.zprofile",
			home .. "/.bashrc",
			home .. "/.bash_profile",
			home .. "/.profile"
		}

		-- Prefer an rc file that already has an lde entry; else the first that exists (to append to).
		local target = nil
		for _, rc in ipairs(rcFiles) do
			if fs.exists(rc) then
				local content = fs.read(rc) or ""
				if content:find(marker, 1, true) then
					if not content:find(marker .. "/tools", 1, true) then
						local updated = content:gsub('export PATH="[^"]*' .. patternMarker .. '[^"]*"', pathLine)
						if updated == content then
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
