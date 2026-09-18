-- arg[0] is <source>/luarocks/install.lua
local scriptDir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local sourceDir = scriptDir:match("^(.*)[/\\][^/\\]*$") or "."
local sep = package.config:sub(1, 1)
local isWindows = sep == "\\"

-- rockspec passes these
local args = table.concat(arg, " ", 1, #arg)

local command
if isWindows then
	command = ('powershell -NoProfile -ExecutionPolicy Bypass -File "%s\\install.ps1" %s'):format(sourceDir, args)
else
	command = ('sh "%s/install.sh" %s'):format(sourceDir, args)
end

local ok, how, code = os.execute(command)
if ok ~= true and ok ~= 0 then
	io.stderr:write(("lde installer failed (%s %s)\n  %s\n"):format(how, code, command))
	os.exit(1)
end
