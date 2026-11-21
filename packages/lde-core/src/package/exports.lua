--- Finds `---@export "C" name fn(a: T, ...): R` annotations for
--- `lde compile --shared` and rewrites the source so each annotated
--- `local function` registers itself in the export registry right after its
--- closing `end` (on the same line, so tracebacks keep their line numbers).
---
--- One pass over the source with a minimal tokenizer: strings and comments are
--- skipped, and only block keywords are counted (function/if/do/repeat open,
--- end/until close), which is enough to find a function's closing `end`.

const glue = require("sea.glue")

const exports = {}

const OPENERS = { ["function"] = true, ["if"] = true, ["do"] = true, ["repeat"] = true }
const CLOSERS = { ["end"] = true, ["until"] = true }

-- These collide with the LuaJIT symbols or the glue's own statics in the same library.
const RESERVED_PREFIXES = { "lua_", "luaL_", "luaJIT_", "luaopen_", "lde_" }

-- `fn` is the documented spelling; `fun` matches LuaCATS and `function` matches Lua.
const SIGNATURE_KEYWORDS = { fn = true, fun = true, ["function"] = true }

---@param src string
---@param pos integer
local function lineAt(src, pos)
	local line = 1
	for _ in src:sub(1, pos):gmatch("\n") do line += 1 end
	return line
end

--- Position after a long bracket (`[[`, `[==[`) opening at `pos`, or nil when `pos` does not open one.
---@param src string
---@param pos integer
---@return integer?
local function skipLongBracket(src, pos)
	const level = src:match("^%[(=*)%[", pos)
	if not level then return nil end
	const _, close = src:find("]" .. level .. "]", pos + #level + 2, true)
	return close and close + 1 or #src + 1
end

---@param src string
---@param pos integer # at the opening quote
local function skipShortString(src, pos)
	const pattern = src:byte(pos) == 34 and '[\\"\n]' or "[\\'\n]"
	local i = pos + 1
	while true do
		const j = src:find(pattern, i)
		if not j then return #src + 1 end
		if src:byte(j) ~= 92 then return j + 1 end
		i = j + 2
	end
end

---@class lde.exports.Annotation
---@field name string? # nil: use the local function's name
---@field params string[]
---@field ret string

--- Splits `fn(a: T): R` into its parameter list and return part.
---@param signature string
---@return string? paramList
---@return string? retPart
local function splitSignature(signature)
	const keyword, paramList, retPart = signature:match("^(%a+)%s*%(([^)]*)%)%s*(.-)$")
	if keyword and SIGNATURE_KEYWORDS[keyword] then return paramList, retPart end
	return nil
end

---@param text string # annotation text after `---@export`
---@return lde.exports.Annotation? annotation
---@return string? err
local function parseAnnotation(text)
	const rest = text:match('^%s+"C"%s+(.-)%s*$')
	if not rest then
		return nil, 'expected `---@export "C" [name] fn(...): type`'
	end

	-- Without a name the signature comes first; `fn fn(...)` still exports a symbol called `fn`.
	local name
	local paramList, retPart = splitSignature(rest)
	if not paramList then
		local signature
		name, signature = rest:match("^([%a_][%w_]*)%s+(.*)$")
		if name then paramList, retPart = splitSignature(signature) end
	end
	if not paramList or not retPart then
		return nil, "expected a `fn(...)` signature"
	end

	local ret = "void"
	if retPart ~= "" then
		const retName = retPart:match("^:%s*([%w_]+%*?)$")
		const resolved = retName and glue.resolveType(retName)
		if not resolved then
			return nil, "unsupported return type '" .. retPart:gsub("^:%s*", "") .. "'"
		end
		ret = resolved
	end

	---@type string[]
	local params = {}
	if paramList:find("%S") then
		for param in (paramList .. ","):gmatch("([^,]*),") do
			const paramName, typeName = param:match("^%s*([%a_][%w_]*)%s*:%s*([%w_]+%*?)%s*$")
			if not paramName then
				return nil, "invalid parameter '" .. param:match("^%s*(.-)%s*$") .. "' (expected `name: type`)"
			end
			const canonical = glue.resolveType(typeName)
			if not canonical or canonical == "void" then
				return nil, "unsupported type '" .. typeName .. "' for parameter '" .. paramName .. "'"
			end
			params[#params + 1] = canonical
		end
	end

	return { name = name, params = params, ret = ret }
end

---@param name string
local function checkSymbol(name)
	for _, prefix in ipairs(RESERVED_PREFIXES) do
		if name:sub(1, #prefix) == prefix then
			return "export name '" .. name .. "' uses the reserved prefix '" .. prefix .. "'"
		end
	end
	return nil
end

--- Line number and text of every `---@export` line comment in `src`, skipping strings and long comments.
---@param src string
local function annotationLines(src)
	---@type { line: integer, text: string }[]
	const found = {}
	local pos = 1
	while true do
		const s = src:find("[\"'%-%[]", pos)
		if not s then break end
		const c = src:byte(s)
		if c == 34 or c == 39 then
			pos = skipShortString(src, s)
		elseif c == 91 then -- '['
			pos = skipLongBracket(src, s) or s + 1
		elseif src:byte(s + 1) ~= 45 then
			pos = s + 1
		else
			const afterLong = src:byte(s + 2) == 91 and skipLongBracket(src, s + 2)
			if afterLong then
				pos = afterLong
			else
				const eol = src:find("\n", s, true) or #src + 1
				if src:find("^%-%-%-@export%f[^%w_]", s) then
					found[#found + 1] = { line = lineAt(src, s), text = (src:sub(s, eol - 1):gsub("%s+$", "")) }
				end
				pos = eol + 1
			end
		end
	end
	return found
end

--- Copies the `---@export` annotations of a Teal source into the Lua that tl
--- generated from it. tl drops comments but keeps every line where it was (a
--- dropped comment becomes a blank line), so each annotation goes back on its
--- own, now blank, line and `exports.process` can scan the result.
---@param luaSrc string # tl output
---@param tealSrc string
---@param tealName string # used in error messages
---@return string? source
---@return string? err
function exports.transplant(luaSrc, tealSrc, tealName)
	if not tealSrc:find("---@export", 1, true) then return luaSrc end

	const lines = {}
	for line in (luaSrc .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end

	for _, annotation in ipairs(annotationLines(tealSrc)) do
		const target = lines[annotation.line]
		if not target or target:find("%S") then
			return nil, tealName .. ":" .. annotation.line
				.. ": tl generated code on this line, so the ---@export cannot be placed; put it on its own line directly above the `local function`"
		end
		lines[annotation.line] = annotation.text
	end
	return table.concat(lines, "\n")
end

--- Rewrites `src` to register its exported functions. Returns `src` unchanged
--- and an empty list when it has no annotations.
---@param src string
---@param chunkName string # used in error messages
---@return string? source
---@return sea.Export[]? exports
---@return string? err
function exports.process(src, chunkName)
	if not src:find("---@export", 1, true) then return src, {} end

	---@param pos integer
	---@param msg string
	local function fail(pos, msg)
		return nil, nil, chunkName .. ":" .. lineAt(src, pos) .. ": " .. msg
	end

	---@type sea.Export[]
	const found = {}
	---@type { depth: integer, export: sea.Export, luaName: string }[]
	const open = {}
	const pieces = {}
	local copiedTo = 0
	local depth = 0
	---@type lde.exports.Annotation?
	local pending
	local pendingPos = 0
	local pos = 1

	while true do
		const s = src:find("[%a_\"'%-%[]", pos)
		if not s then break end
		const c = src:byte(s)

		if c == 45 then -- '-'
			if src:byte(s + 1) ~= 45 then
				pos = s + 1
			else
				const afterLong = src:byte(s + 2) == 91 and skipLongBracket(src, s + 2)
				if afterLong then
					pos = afterLong
				else
					const eol = src:find("\n", s, true) or #src + 1
					if src:find("^%-%-%-@export%f[^%w_]", s) then
						if pending then return fail(s, "two ---@export annotations on one function") end
						const annotation, err = parseAnnotation(src:sub(s + 10, eol - 1))
						if not annotation then return fail(s, err --[[@as string]]) end
						pending, pendingPos = annotation, s
					end
					pos = eol + 1
				end
			end
		elseif pending then
			const luaName, luaParams, after = src:match("^local%s+function%s+([%a_][%w_]*)%s*%(([^)]*)%)()", s)
			if not luaName then
				return fail(pendingPos, "---@export must be directly followed by a `local function name(...)` declaration")
			end

			local luaArity = 0
			for param in luaParams:gmatch("[^,]+") do
				if param:find("...", 1, true) then
					return fail(s, "exported function '" .. luaName .. "' cannot be variadic")
				end
				if param:find("%S") then luaArity += 1 end
			end
			if luaArity ~= #pending.params then
				return fail(s, string.format("exported function '%s' takes %d parameters but its ---@export declares %d",
					luaName, luaArity, #pending.params))
			end

			---@type sea.Export
			const export = { name = pending.name or luaName, params = pending.params, ret = pending.ret }
			const err = checkSymbol(export.name)
			if err then return fail(pendingPos, err) end

			open[#open + 1] = { depth = depth, export = export, luaName = luaName }
			found[#found + 1] = export
			depth += 1
			pending = nil
			pos = after
		elseif c == 34 or c == 39 then
			pos = skipShortString(src, s)
		elseif c == 91 then -- '['
			pos = skipLongBracket(src, s) or s + 1
		else
			const word = src:match("^[%a_][%w_]*", s)
			pos = s + #word
			if OPENERS[word] then
				depth += 1
			elseif CLOSERS[word] then
				depth -= 1
				const top = open[#open]
				if top and top.depth == depth then
					pieces[#pieces + 1] = src:sub(copiedTo + 1, pos - 1)
					pieces[#pieces + 1] = string.format(' debug.getregistry()["lde.exports"]["%s"] = %s',
						top.export.name, top.luaName)
					copiedTo = pos - 1
					open[#open] = nil
				end
			end
		end
	end

	if pending then
		return fail(pendingPos, "---@export must be directly followed by a `local function name(...)` declaration")
	end
	if #open > 0 then
		return fail(#src, "could not find the end of exported function '" .. open[#open].luaName .. "'")
	end

	pieces[#pieces + 1] = src:sub(copiedTo + 1)
	return table.concat(pieces), found
end

return exports
