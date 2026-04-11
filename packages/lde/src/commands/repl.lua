local ansi      = require("ansi")
local readline  = require("readline")
local highlight = require("readline.highlight")

local lde = require("lde-core")
local run = require("lde-core.package.run")

---@param _args clap.Args
local function repl(_args)
	ansi.printf("{blue}{bold}lde repl{reset} — LuaJIT interactive shell")
	ansi.printf("{gray}Type {bold}exit(){reset}{gray} or press Ctrl+C to quit.\n")

	local savedPath, savedCPath = package.path, package.cpath

	local pkg = lde.Package.open()
	if pkg then
		pkg:build()
		pkg:installDependencies()

		local luaPath, luaCPath = run.getLuaPaths(pkg)
		package.path = luaPath .. savedPath
		package.cpath = luaCPath .. savedCPath

		local config = pkg:readConfig()
		ansi.printf("{gray}Project: {green}%s {gray}(%s)", config.name or "unknown", pkg:getDir())
	end

	local buffer = ""

	local G = setmetatable({}, { __index = _G })
	G._ENV = G
	G.exit = function(code) os.exit(code or 0) end

	local function pretty(val, indent, seen)
		indent = indent or 0
		seen = seen or {}
		local t = type(val)
		if t == "string" then
			return ansi.format("{green}\"" .. val:gsub('"', '\\"') .. "\"")
		elseif t ~= "table" then
			return ansi.format("{yellow}" .. tostring(val))
		elseif seen[val] then
			return ansi.format("{gray}<circular>")
		end
		seen[val] = true
		local pad = string.rep("  ", indent)
		local inner = string.rep("  ", indent + 1)
		local items = {}
		for k, v in pairs(val) do
			local key = type(k) == "string"
				and ansi.format("{cyan}" .. k .. "{reset}")
				or ansi.format("{magenta}[" .. tostring(k) .. "]{reset}")
			items[#items + 1] = inner .. key .. " = " .. pretty(v, indent + 1, seen)
		end
		seen[val] = nil
		if #items == 0 then return "{}" end
		return "{\n" .. table.concat(items, ",\n") .. "\n" .. pad .. "}"
	end

	-- Rewrite `local x, y = ...` to `x, y = ...` so variables persist in G across lines.
	local function delocal(s)
		return (s:gsub("^%s*local%s+([%a_][%w_%s,]-)%s*=", "%1 ="))
	end

	while true do
		local prompt = ansi.format(buffer ~= "" and "{gray}...{reset} " or "{blue}>{reset} ")
		local line = readline.read(prompt, highlight)

		if line == nil or line == "exit()" or line == "quit()" then
			break
		end

		buffer = buffer == "" and delocal(line) or (buffer .. "\n" .. delocal(line))

		local chunk, err = loadstring("return " .. buffer, "repl") or loadstring(buffer, "repl")

		if chunk then
			setfenv(chunk, G)
			local ok, result = pcall(chunk)
			if ok then
				if result ~= nil then ansi.printf("{gray}={reset} %s", pretty(result)) end
			else
				ansi.printf("{red}%s", tostring(result))
			end
			buffer = ""
		elseif err and err:find("<eof>") then
			-- incomplete, keep buffering
		else
			ansi.printf("{red}%s", tostring(err))
			buffer = ""
		end
	end

	package.path = savedPath
	package.cpath = savedCPath
end

return repl
