const ansi      = require("ansi")
const readline  = require("readline")
local highlight = require("ansi.highlight")

const lde     = require("lde-core")
const runtime = require("lde-core.runtime")
const prompt  = require("lde.util.prompt")

---@param v any
---@return boolean
local function isGuestValue(v)
	if type(v) ~= "table" then return false end
	local mt = getmetatable(v)
	return mt ~= nil and rawget(mt, "_is_lua_value") == true
end

---@param _args clap.Args
local function repl(_args)
	-- Piped/redirected stdin behaves like a stdin script: no banner or prompts (those are interactive furniture).
	if prompt.interactive then
		ansi.printf("{blue}{bold}lde repl{reset} — LuaJIT interactive shell")
		ansi.printf("{gray}Type {bold}exit(){reset}{gray} or press Ctrl+C to quit.\n")
	end

	local globals = {
		exit = function(code) os.exit(code or 0) end,
	}

	const pkg = lde.Package.open()
	local state, g, cleanup
	if pkg then
		-- Build + install + guest state with the package's target/ on the module paths, same as `lde run`.
		state, g, cleanup = pkg:createState({ args = { [0] = "repl" }, globals = globals })

		if prompt.interactive then
			const config = pkg:readConfig()
			ansi.printf("{gray}Project: {green}%s {gray}(%s)", config.name or "unknown", pkg:getDir())
		end
	else
		state, g, cleanup = runtime.createState({ args = { [0] = "repl" }, globals = globals })
	end
	g["_ENV"] = g

	local buffer = ""

	---@param val any
	---@param indent number?
	---@param seen table?
	---@param depth number?
	local function pretty(val, indent, seen, depth)
		indent = indent or 0
		seen   = seen or {}
		depth  = depth or 0
		const t = type(val)
		if t == "string" then
			return ansi.format("{green}\"" .. val:gsub('"', '\\"') .. "\"")
		elseif t ~= "table" then
			return ansi.format("{yellow}" .. tostring(val))
		end

		const guest = isGuestValue(val)
		if guest and val._type ~= "table" then
			return ansi.format("{yellow}%s", tostring(val))
		end
		if not guest and seen[val] then
			return ansi.format("{gray}<circular>")
		end
		if depth >= 10 then
			return ansi.format("{gray}{...}")
		end
		seen[val] = true

		const pad   = string.rep("  ", indent)
		const inner = string.rep("  ", indent + 1)
		local items = {}
		const iter  = guest and val.pairs or pairs
		for k, v in iter(val) do
			const key = type(k) == "string"
				and ansi.format("{cyan}" .. k .. "{reset}")
				or ansi.format("{magenta}[" .. tostring(k) .. "]{reset}")
			items[#items + 1] = inner .. key .. " = " .. pretty(v, indent + 1, seen, depth + 1)
		end
		seen[val] = nil
		if #items == 0 then return "{}" end
		return "{\n" .. table.concat(items, ",\n") .. "\n" .. pad .. "}"
	end

	-- Desugar local/const so names persist in g across lines (const is a soft keyword, so a global keeps the value).
	---@param s string
	local function delocal(s)
		s = s:gsub("^%s*local%s+function%s+([%a_][%w_]*)%s*%(", "function %1(")
		s = s:gsub("^%s*local%s+([%a_][%w_%s,]-)%s*=", "%1 =")
		return (s:gsub("^%s*const%s+([%a_][%w_%s,]-)%s*=", "%1 ="))
	end

	---@param line string
	---@param pos number
	local function complete(line, pos)
		const before = line:sub(1, pos)
		const word   = before:match("[%a_][%w_%.]*$")
		if not word or word == "" then return nil end

		local obj, prefix
		const dot = word:find("%.[^%.]*$")
		if dot then
			const obj_path = word:sub(1, dot - 1)
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
		local line
		if prompt.interactive then
			local p = ansi.format(buffer ~= "" and "{gray}...{reset} " or "{blue}>{reset} ")
			line = readline.read(p, highlight, complete)
		else
			-- No prompts: they would pollute `echo ... | lde repl` / `lde repl < script.lua` output.
			line = io.read()
		end

		if line == nil or line == "exit()" or line == "quit()" then
			break
		end

		buffer = buffer == "" and delocal(line) or (buffer .. "\n" .. delocal(line))

		const chunk = state:load(buffer, "repl")
		const ok, result = chunk:pcall()
		if ok then
			if result ~= nil then ansi.printf("{gray}={reset} %s", pretty(result)) end
			buffer = ""
		elseif tostring(result):find("<eof>") then
		else
			ansi.printf("{red}%s", tostring(result))
			buffer = ""
		end
	end

	state:close()
	cleanup()
end

return repl
