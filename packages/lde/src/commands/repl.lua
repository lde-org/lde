local ansi      = require("ansi")
local readline  = require("readline")
local highlight = require("readline.highlight")

local lde     = require("lde-core")
local runtime = require("lde-core.runtime")

---@param v any
---@return boolean
local function isGuestValue(v)
	if type(v) ~= "table" then return false end
	local mt = getmetatable(v)
	return mt ~= nil and rawget(mt, "_is_lua_value") == true
end

---@param _args clap.Args
local function repl(_args)
	ansi.printf("{blue}{bold}lde repl{reset} — LuaJIT interactive shell")
	ansi.printf("{gray}Type {bold}exit(){reset}{gray} or press Ctrl+C to quit.\n")

	local globals = {
		exit = function(code) os.exit(code or 0) end,
	}

	local pkg = lde.Package.open()
	local state, g, cleanup
	if pkg then
		-- Build + install + guest state with the package's target/ on the
		-- module paths — the same setup lde run uses.
		state, g, cleanup = pkg:createState({ args = { [0] = "repl" }, globals = globals })

		local config = pkg:readConfig()
		ansi.printf("{gray}Project: {green}%s {gray}(%s)", config.name or "unknown", pkg:getDir())
	else
		state, g, cleanup = runtime.createState({ args = { [0] = "repl" }, globals = globals })
	end
	g["_ENV"] = g

	local buffer = ""

	---@param val any
	---@param indent number?
	---@param seen table?
	---@param depth number?
	---@return string
	local function pretty(val, indent, seen, depth)
		indent = indent or 0
		seen   = seen or {}
		depth  = depth or 0
		local t = type(val)
		if t == "string" then
			return ansi.format("{green}\"" .. val:gsub('"', '\\"') .. "\"")
		elseif t ~= "table" then
			return ansi.format("{yellow}" .. tostring(val))
		end

		local guest = isGuestValue(val)
		if guest and val._type ~= "table" then
			-- guest thread/userdata — nothing to walk
			return ansi.format("{yellow}%s", tostring(val))
		end
		if not guest and seen[val] then
			return ansi.format("{gray}<circular>")
		end
		if depth >= 10 then
			return ansi.format("{gray}{...}")
		end
		seen[val] = true

		local pad   = string.rep("  ", indent)
		local inner = string.rep("  ", indent + 1)
		local items = {}
		local iter  = guest and val.pairs or pairs
		for k, v in iter(val) do
			local key = type(k) == "string"
				and ansi.format("{cyan}" .. k .. "{reset}")
				or ansi.format("{magenta}[" .. tostring(k) .. "]{reset}")
			items[#items + 1] = inner .. key .. " = " .. pretty(v, indent + 1, seen, depth + 1)
		end
		seen[val] = nil
		if #items == 0 then return "{}" end
		return "{\n" .. table.concat(items, ",\n") .. "\n" .. pad .. "}"
	end

	-- Desugar local and const declarations so names persist in g across lines:
	--   `local function name(...)` → `function name(...)` (lands in the chunk env)
	--   `local x, y = ...`         → `x, y = ...`
	--   `const x, y = ...`         → `x, y = ...` (const is a soft keyword, so a
	--                            global keeps the value across lines)
	---@param s string
	---@return string
	local function delocal(s)
		s = s:gsub("^%s*local%s+function%s+([%a_][%w_]*)%s*%(", "function %1(")
		s = s:gsub("^%s*local%s+([%a_][%w_%s,]-)%s*=", "%1 =")
		return (s:gsub("^%s*const%s+([%a_][%w_%s,]-)%s*=", "%1 ="))
	end

	---@param line string
	---@param pos number
	local function complete(line, pos)
		local before = line:sub(1, pos)
		local word   = before:match("[%a_][%w_%.]*$")
		if not word or word == "" then return nil end

		local obj, prefix
		local dot = word:find("%.[^%.]*$")
		if dot then
			local obj_path = word:sub(1, dot - 1)
			prefix = word:sub(dot + 1)
			obj = g
			for part in obj_path:gmatch("[%a_][%w_]*") do
				if type(obj) == "table" then
					obj = obj[part]
				else
					return nil
				end
			end
			if type(obj) ~= "table" then return nil end
		else
			prefix = word
			obj    = nil
		end

		local candidates, seen = {}, {}
		---@param t table<string, boolean>
		local function scan(t)
			---@param k string
			local function visit(k)
				if type(k) == "string" and not seen[k]
					and k:sub(1, #prefix) == prefix and k ~= prefix then
					seen[k] = true
					candidates[#candidates + 1] = k
				end
			end
			if isGuestValue(t) then
				for k in t:pairs() do visit(k) end
			else
				for k in pairs(t) do visit(k) end
			end
		end

		if obj then
			scan(obj)
		else
			scan(g)
		end

		if #candidates == 0 then return nil end
		table.sort(candidates)
		return candidates[1]:sub(#prefix + 1)
	end

	while true do
		local prompt = ansi.format(buffer ~= "" and "{gray}...{reset} " or "{blue}>{reset} ")
		local line = readline.read(prompt, highlight, complete)

		if line == nil or line == "exit()" or line == "quit()" then
			break
		end

		buffer = buffer == "" and delocal(line) or (buffer .. "\n" .. delocal(line))

		local chunk = state:load(buffer, "repl")
		local ok, result = chunk:pcall()
		if ok then
			if result ~= nil then ansi.printf("{gray}={reset} %s", pretty(result)) end
			buffer = ""
		elseif tostring(result):find("<eof>") then
			-- incomplete, keep buffering
		else
			ansi.printf("{red}%s", tostring(result))
			buffer = ""
		end
	end

	state:close()
	cleanup()
end

return repl
