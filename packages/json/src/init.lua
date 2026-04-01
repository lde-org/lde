local json   = {}
local ffi    = require("ffi")
local strbuf = require("string.buffer")

ffi.cdef [[
  void* memchr(const void* s, int c, size_t n);
  void* memcpy(void* dst, const void* src, size_t n);
]]
local C         = ffi.C
local cast      = ffi.cast
local u8p       = "const uint8_t*"

-- ── types ─────────────────────────────────────────────────────────────────────

---@alias json.Primitive   string | number | boolean | nil
---@alias json.Value       json.Primitive | json.Object | json.Array | table
---@alias json.Object      table<string, json.Value>
---@alias json.Array       json.Value[]
---@alias json.KeyStyle    "ident" | "single" | "double"
---@alias json.StringStyle "single" | "double"

---@class json.KeyMeta
---@field keyStyle   json.KeyStyle
---@field before     string | nil
---@field between    string | nil
---@field afterColon string | nil
---@field afterValue string | nil
---@field valueStyle json.StringStyle | nil

---@class json.TableMeta
---@field __trailingComma boolean
---@field __closingTrivia string | nil
---@field [string]        json.KeyMeta
---@field [integer]       json.KeyMeta

-- ── weak stores ───────────────────────────────────────────────────────────────

---@type table<table, string[]>
local keyStore  = setmetatable({}, { __mode = "k" })
---@type table<table, json.TableMeta>
local metaStore = setmetatable({}, { __mode = "k" })

-- ── encode ────────────────────────────────────────────────────────────────────

---@type table<string, string>
local dq_esc    = {
	['"'] = '\\"',
	['\\'] = '\\\\',
	['\b'] = '\\b',
	['\f'] = '\\f',
	['\n'] = '\\n',
	['\r'] = '\\r',
	['\t'] = '\\t'
}
---@type table<string, string>
local sq_esc    = {
	["'"] = "\\'",
	['\\'] = '\\\\',
	['\b'] = '\\b',
	['\f'] = '\\f',
	['\n'] = '\\n',
	['\r'] = '\\r',
	['\t'] = '\\t'
}

-- Hoisted callbacks — no FNEW NYI
local function dq_replace(c) return dq_esc[c] or string.format("\\u%04x", string.byte(c)) end
local function sq_replace(c) return sq_esc[c] or string.format("\\u%04x", string.byte(c)) end

-- 256-byte lookup: 1 = needs escaping in double-quoted context
local dq_needs = ffi.new("uint8_t[256]")
for i = 0, 31 do dq_needs[i] = 1 end
dq_needs[34] = 1 -- "
dq_needs[92] = 1 -- \

-- 256-byte lookup: 1 = needs escaping in single-quoted context
local sq_needs = ffi.new("uint8_t[256]")
for i = 0, 31 do sq_needs[i] = 1 end
sq_needs[39] = 1 -- '
sq_needs[92] = 1 -- \

---@param tape  string.buffer
---@param s     string
---@param style json.StringStyle | nil
local function putString(tape, s, style)
	local len = #s
	if style == "single" then
		tape:put("'")
		-- fast path: scan for any byte needing escape
		local p = cast(u8p, s)
		local clean = true
		for i = 0, len - 1 do
			if sq_needs[p[i]] == 1 then
				clean = false; break
			end
		end
		if clean then tape:put(s) else tape:put((string.gsub(s, "[%z\1-\31'\\]", sq_replace))) end
		tape:put("'")
	else
		tape:put('"')
		local p = cast(u8p, s)
		local clean = true
		for i = 0, len - 1 do
			if dq_needs[p[i]] == 1 then
				clean = false; break
			end
		end
		if clean then tape:put(s) else tape:put((string.gsub(s, '[%z\1-\31"\\]', dq_replace))) end
		tape:put('"')
	end
end

---@type fun(tape: string.buffer, v: json.Value, indent: string, level: integer, valueStyle: json.StringStyle | nil)
local putValue -- forward decl

---@param t table
---@return boolean
local function isArray(t)
	if keyStore[t] then return false end
	local i = 0
	for _ in pairs(t) do
		i = i + 1
		if t[i] == nil then return false end
	end
	return true
end

---@param tape   string.buffer
---@param t      json.Array
---@param indent string
---@param level  integer
local function putArray(tape, t, indent, level)
	local n = #t
	if n == 0 then
		tape:put("[]"); return
	end
	local meta          = metaStore[t]
	local nextIndent    = string.rep(indent, level + 1)
	local defaultBefore = "\n" .. nextIndent
	local closing       = (meta and meta.__closingTrivia) or ("\n" .. string.rep(indent, level))
	tape:put("[")
	for i = 1, n do
		if i > 1 then tape:put(",") end
		local km = meta and meta[i]
		tape:put((km and km.before) or defaultBefore)
		putValue(tape, t[i], indent, level + 1, km and km.valueStyle)
		local av = km and km.afterValue
		if av and av ~= "" then tape:put(av) end
	end
	if meta and meta.__trailingComma then tape:put(",") end
	tape:put(closing)
	tape:put("]")
end

---@param tape   string.buffer
---@param t      json.Object
---@param indent string
---@param level  integer
local function putObject(tape, t, indent, level)
	local keys = keyStore[t]
	if not keys then
		keys = {}
		for k in pairs(t) do keys[#keys + 1] = k end
		table.sort(keys)
	end
	local n = #keys
	if n == 0 then
		tape:put("{}"); return
	end
	local meta = metaStore[t]

	if not meta then
		-- Write directly to tape — no scratch buffer alloc/stitch
		-- Use a mark to potentially rewrite as inline, but that costs more than it saves.
		-- Just always pretty-print: the extra newlines are negligible vs allocation overhead.
		local nextIndent = string.rep(indent, level + 1)
		tape:put("{\n")
		for i, k in ipairs(keys) do
			if i > 1 then tape:put(",\n") end
			tape:put(nextIndent)
			putString(tape, tostring(k), nil)
			tape:put(": ")
			putValue(tape, t[k], indent, level + 1, nil)
		end
		tape:put("\n")
		tape:put(string.rep(indent, level))
		tape:put("}")
		return
	end

	tape:put("{")
	for i, k in ipairs(keys) do
		if i > 1 then tape:put(",") end
		local km = meta[k]
		tape:put((km and km.before) or " ")
		local ks = km and km.keyStyle
		if ks == "ident" then
			tape:put(tostring(k))
		else
			putString(tape, tostring(k), ks)
		end
		tape:put((km and km.between) or "")
		tape:put(":")
		tape:put((km and km.afterColon) or " ")
		putValue(tape, t[k], indent, level + 1, km and km.valueStyle)
		local av = km and km.afterValue
		if av and av ~= "" then tape:put(av) end
	end
	if meta.__trailingComma then tape:put(",") end
	tape:put(meta.__closingTrivia or " ")
	tape:put("}")
end

local floor = math.floor
local huge  = math.huge

putValue    = function(tape, v, indent, level, valueStyle)
	local t = type(v)
	if t == "nil" or v == json.null then
		tape:put("null")
	elseif t == "boolean" then
		tape:put(v and "true" or "false")
	elseif t == "number" then
		if v ~= v then
			tape:put("NaN")
		elseif v == huge then
			tape:put("Infinity")
		elseif v == -huge then
			tape:put("-Infinity")
		elseif v == floor(v) then
			tape:put(string.format("%d", v))
		else
			tape:put(tostring(v))
		end
	elseif t == "string" then
		putString(tape, v, valueStyle)
	elseif t == "table" then
		if isArray(v) then
			putArray(tape, v, indent, level)
		else
			putObject(tape, v, indent, level)
		end
	else
		error("unsupported type: " .. t)
	end
end

---@param t     table
---@param key   string
---@param value json.Value
function json.addField(t, key, value)
	t[key] = value
	local keys = keyStore[t]
	if not keys then
		keys = {}; keyStore[t] = keys
	end
	keys[#keys + 1] = key
end

---@param t   table
---@param key string
function json.removeField(t, key)
	t[key] = nil
	local keys = keyStore[t]
	if not keys then return end
	for i, k in ipairs(keys) do
		if k == key then
			table.remove(keys, i); return
		end
	end
end

---@param value json.Value
---@return string
function json.encode(value)
	local tape = strbuf.new()
	putValue(tape, value, "\t", 0, nil)
	tape:put("\n")
	return tape:tostring()
end

-- ── decoder ───────────────────────────────────────────────────────────────────

---@type ffi.cdata*
local src_ptr -- kept alive by src_s
---@type integer
local src_len
---@type string
local src_s

-- 256-byte whitespace lookup: 1 = whitespace
local ws_tab = ffi.new("uint8_t[256]")
ws_tab[32] = 1; ws_tab[9] = 1; ws_tab[10] = 1; ws_tab[13] = 1

-- 256-byte ident-continue lookup: 1 = valid [%w_$]
local ident_tab = ffi.new("uint8_t[256]")
for i = 48, 57 do ident_tab[i] = 1 end  -- 0-9
for i = 65, 90 do ident_tab[i] = 1 end  -- A-Z
for i = 97, 122 do ident_tab[i] = 1 end -- a-z
ident_tab[95] = 1                       -- _
ident_tab[36] = 1                       -- $

---@param pos integer 1-based
---@return integer    1-based
local function skipWS(pos)
	local i = pos - 1
	while i < src_len and ws_tab[src_ptr[i]] == 1 do i = i + 1 end
	return i + 1
end

---@param pos         integer 1-based, sitting on '/'
---@param triviaStart integer 1-based start of trivia span
---@return string  trivia
---@return integer 1-based position after trivia
local function collectComments(pos, triviaStart)
	while pos <= src_len do
		if src_ptr[pos - 1] ~= 47 then break end
		local b1 = src_ptr[pos]
		if b1 == 47 then -- '//'
			local nl = C.memchr(src_ptr + pos + 1, 10, src_len - pos - 1)
			pos = nl ~= nil and (cast(u8p, nl) - src_ptr + 2) or (src_len + 1)
		elseif b1 == 42 then -- '/*'
			local p     = src_ptr + pos + 1
			local rem   = src_len - pos - 1
			local found = false
			while rem > 0 do
				local star = C.memchr(p, 42, rem)
				if star == nil then error("unterminated block comment") end
				local sp  = cast(u8p, star)
				local off = sp - src_ptr
				if off + 1 < src_len and src_ptr[off + 1] == 47 then
					pos = off + 3; found = true; break
				end
				p = sp + 1; rem = src_len - (off + 1)
			end
			if not found then error("unterminated block comment") end
		else
			break
		end
		pos = skipWS(pos)
	end
	return string.sub(src_s, triviaStart, pos - 1), pos
end

---@param pos integer 1-based
---@return string | nil trivia  nil when empty (avoids alloc)
---@return integer      1-based position after trivia
local function collectTrivia(pos)
	local npos = skipWS(pos)
	if npos <= src_len and src_ptr[npos - 1] == 47 then
		return collectComments(npos, pos)
	end
	if npos == pos then return nil, npos end
	return string.sub(src_s, pos, npos - 1), npos
end

---@type fun(pos: integer): json.Value, integer, json.StringStyle | nil
local decodeValue -- forward decl

---@type table<integer, string>
local escapeMap = {
	[34] = '"',
	[39] = "'",
	[92] = '\\',
	[47] = '/',
	[98] = '\b',
	[102] = '\f',
	[110] = '\n',
	[114] = '\r',
	[116] = '\t'
}

---@param pos integer 1-based, pointing at opening quote
---@return string            decoded string value
---@return integer           1-based position after closing quote
---@return json.StringStyle  quote style used
local function decodeString(pos)
	local quote = src_ptr[pos - 1]
	local style = (quote == 39) and "single" or "double" --[[@as json.StringStyle]]
	local i     = pos + 1 -- 1-based first content char
	local len   = src_len

	-- Fast path: find closing quote first, then check for backslash before it
	local pq    = C.memchr(src_ptr + i - 1, quote, len - i + 1)
	if pq == nil then error("unterminated string") end
	local q_off = cast(u8p, pq) - src_ptr -- 0-based offset of closing quote

	-- Check if there's a backslash before the closing quote
	local pbs = C.memchr(src_ptr + i - 1, 92, q_off - (i - 1))
	if pbs == nil then
		-- No escapes at all — return substring directly, zero copies
		local s = q_off > i - 1 and string.sub(src_s, i, q_off) or ""
		return s, q_off + 2, style
	end

	-- Slow path: has escapes
	local buf = {}
	while i <= len do
		local rem    = len - i + 1
		local base   = src_ptr + i - 1
		local pbs2   = C.memchr(base, 92, rem)
		local pq2    = C.memchr(base, quote, rem)
		local bs_off = pbs2 ~= nil and (cast(u8p, pbs2) - src_ptr) or len
		local q_off2 = pq2 ~= nil and (cast(u8p, pq2) - src_ptr) or len
		if q_off2 <= bs_off then
			if q_off2 >= len then error("unterminated string") end
			if q_off2 > i - 1 then buf[#buf + 1] = string.sub(src_s, i, q_off2) end
			return table.concat(buf), q_off2 + 2, style
		end
		if bs_off > i - 1 then buf[#buf + 1] = string.sub(src_s, i, bs_off) end
		local esc = src_ptr[bs_off + 1]
		if esc == 117 then
			buf[#buf + 1] = string.char(tonumber(string.sub(src_s, bs_off + 2, bs_off + 5), 16))
			i = bs_off + 7
		elseif esc == 10 or esc == 13 then
			i = bs_off + 3
		else
			buf[#buf + 1] = escapeMap[esc] or string.char(esc)
			i = bs_off + 3
		end
	end
	error("unterminated string")
end

---@param pos integer 1-based
---@return string  identifier
---@return integer 1-based position after identifier
local function decodeIdentifier(pos)
	local i = pos - 1 -- 0-based
	-- first char must be [%a_$]
	local b = src_ptr[i]
	if not ((b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95 or b == 36) then
		error("invalid identifier at pos " .. pos)
	end
	i = i + 1
	while i < src_len and ident_tab[src_ptr[i]] == 1 do i = i + 1 end
	return string.sub(src_s, pos, i), i + 1
end

---@param pos integer 1-based
---@return number  parsed number
---@return integer 1-based position after number
local function decodeNumber(pos)
	-- Fast path: plain integer
	local i   = pos - 1
	local neg = src_ptr[i] == 45 -- '-'
	if neg then i = i + 1 end
	local b = src_ptr[i]
	if b >= 48 and b <= 57 then
		if b == 48 then
			local b2 = src_ptr[i + 1]
			if b2 == 120 or b2 == 88 then goto slow end -- hex
		end
		local n = 0
		while i < src_len do
			b = src_ptr[i]
			if b < 48 or b > 57 then break end
			n = n * 10 + (b - 48)
			i = i + 1
		end
		if b ~= 46 and b ~= 101 and b ~= 69 then -- not '.','e','E'
			return neg and -n or n, i + 1
		end
	end
	::slow::
	local hex = string.match(src_s, "^-?0[xX]%x+", pos)
	if hex then return tonumber(hex), pos + #hex end
	local sub = string.sub(src_s, pos, pos + 8)
	if sub:sub(1, 8) == "Infinity" then return huge, pos + 8 end
	if sub:sub(1, 9) == "+Infinity" then return huge, pos + 9 end
	if sub:sub(1, 9) == "-Infinity" then return -huge, pos + 9 end
	if sub:sub(1, 3) == "NaN" then return 0 / 0, pos + 3 end
	local numStr = string.match(src_s, "^[+-]?%d+%.?%d*[eE]?[+-]?%d*", pos)
	return tonumber(numStr), pos + #numStr
end

---@param pos integer 1-based, pointing at '['
---@return json.Array
---@return integer    1-based position after ']'
local function decodeArray(pos)
	local arr          = {} --[[@as json.Array]]
	local meta         = nil --[[@as json.TableMeta | nil]]

	local trivia, npos = collectTrivia(pos + 1)
	pos                = npos
	if src_ptr[pos - 1] == 93 then -- ']'
		if trivia then
			meta = { __trailingComma = false, __closingTrivia = trivia }
			metaStore[arr] = meta
		end
		return arr, pos + 1
	end

	local i = 0
	while true do
		i = i + 1
		local val, vstyle
		val, pos, vstyle = decodeValue(pos)
		arr[i] = val

		local afterVal, npos2 = collectTrivia(pos)
		pos = npos2
		local c = src_ptr[pos - 1]

		if trivia or afterVal or vstyle then
			if not meta then
				meta = { __trailingComma = false }; metaStore[arr] = meta
			end
			meta[i] = { before = trivia, afterValue = afterVal, valueStyle = vstyle } --[[@as json.KeyMeta]]
		end

		if c == 93 then -- ']'
			if meta then meta.__closingTrivia = "" end
			return arr, pos + 1
		end
		if c ~= 44 then error("expected ',' or ']'") end
		pos = pos + 1
		trivia, pos = collectTrivia(pos)
		if src_ptr[pos - 1] == 93 then
			if not meta then
				meta = { __trailingComma = false }; metaStore[arr] = meta
			end
			meta.__trailingComma = true
			meta.__closingTrivia = trivia
			return arr, pos + 1
		end
	end
end

---@param pos integer 1-based, pointing at '{'
---@return json.Object
---@return integer     1-based position after '}'
local function decodeObject(pos)
	local obj          = {} --[[@as json.Object]]
	local keys         = {} --[[@as string[] ]]
	local meta         = nil --[[@as json.TableMeta | nil]]
	keyStore[obj]      = keys

	local trivia, npos = collectTrivia(pos + 1)
	pos                = npos
	if src_ptr[pos - 1] == 125 then -- '}'
		if trivia then
			meta = { __trailingComma = false, __closingTrivia = trivia }
			metaStore[obj] = meta
		end
		return obj, pos + 1
	end

	while true do
		local c = src_ptr[pos - 1]
		local key, keyStyle
		if c == 34 or c == 39 then
			local style
			key, pos, style = decodeString(pos)
			keyStyle = style
		else
			key, pos = decodeIdentifier(pos)
			keyStyle = "ident" --[[@as json.KeyStyle]]
		end

		local between, npos2 = collectTrivia(pos)
		pos = npos2
		if src_ptr[pos - 1] ~= 58 then error("expected ':'") end
		pos = pos + 1
		local afterColon, npos3 = collectTrivia(pos)
		pos = npos3

		local val, vstyle
		val, pos, vstyle = decodeValue(pos)
		obj[key] = val
		keys[#keys + 1] = key

		local afterVal, npos4 = collectTrivia(pos)
		pos = npos4

		if trivia or between or afterColon or afterVal or vstyle
			or keyStyle == "single" or keyStyle == "ident" then
			if not meta then
				meta = { __trailingComma = false }; metaStore[obj] = meta
			end
			meta[key] = {
				before = trivia,
				keyStyle = keyStyle, --[[@as json.KeyStyle]]
				between = between,
				afterColon = afterColon,
				afterValue = afterVal,
				valueStyle = vstyle
			} --[[@as json.KeyMeta]]
		end

		c = src_ptr[pos - 1]
		if c == 125 then -- '}'
			if meta then meta.__closingTrivia = "" end
			return obj, pos + 1
		end
		if c ~= 44 then error("expected ',' or '}'") end
		pos = pos + 1
		trivia, pos = collectTrivia(pos)
		if src_ptr[pos - 1] == 125 then
			if not meta then
				meta = { __trailingComma = false }; metaStore[obj] = meta
			end
			meta.__trailingComma = true
			meta.__closingTrivia = trivia
			return obj, pos + 1
		end
	end
end

---@param pos integer 1-based
---@return json.Value
---@return integer           1-based position after value
---@return json.StringStyle | nil
decodeValue = function(pos)
	local trivia
	trivia, pos = collectTrivia(pos)
	local c = src_ptr[pos - 1]
	if c == 34 or c == 39 then
		return decodeString(pos)
	elseif c == 123 then
		return decodeObject(pos)
	elseif c == 91 then
		return decodeArray(pos)
	elseif c == 116 then
		return true, pos + 4, nil
	elseif c == 102 then
		return false, pos + 5, nil
	elseif c == 110 then
		return json.null, pos + 4, nil
	else
		return decodeNumber(pos)
	end
end

json.null = setmetatable({}, { __tostring = function() return "null" end })

---@param s string
---@return json.Value
function json.decode(s)
	src_s   = s
	src_len = #s
	src_ptr = cast(u8p, s)
	return decodeValue(1)
end

return json
