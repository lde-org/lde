local json   = {}
local ffi    = require("ffi")
local strbuf = require("string.buffer")

ffi.cdef [[
  void* memchr(const void* s, int c, size_t n);

  /* 16-byte token. All decoded JSON lives in a flat json_tok array.
     No Lua table allocations for the parsed document. */
  typedef struct {
    uint8_t  type;     /* TY_* constants below */
    uint8_t  flags;    /* string: 1=has_escapes */
    uint16_t pad;
    uint32_t next;     /* next sibling index (0 = none) */
    union {
      struct { uint32_t str_off; uint32_t str_len; };
      double   num;
      struct { uint32_t child;   uint32_t count;   };
    };
  } json_tok;

  typedef struct { uint32_t start; uint32_t count; } json_keyslice;
]]

local C          = ffi.C
local cast       = ffi.cast
local u8p        = "const uint8_t*"

-- token type constants
local TY_NULL    = 0
local TY_FALSE   = 1
local TY_TRUE    = 2
local TY_INT     = 3
local TY_FLOAT   = 4
local TY_STRING  = 5
local TY_ARRAY   = 6
local TY_OBJECT  = 7

-- ── LuaCATS types ─────────────────────────────────────────────────────────────

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

---@class json.Token : ffi.cdata*
---@field type     integer
---@field flags    integer
---@field next     integer
---@field str_off  integer
---@field str_len  integer
---@field num      number
---@field child    integer
---@field count    integer

---@class json.KeySlice : ffi.cdata*
---@field start integer
---@field count integer

---@class json.Doc
---@field toks  json.Token[]  token arena
---@field src   string        original source string
---@field ntoks integer       number of tokens used

-- ── token arena (per-decode, grown as needed) ─────────────────────────────────

local TOK_INIT   = 4096
local tok_ct     = ffi.typeof("json_tok")
local tok_arr_ct = ffi.typeof("json_tok[?]")
local ks_ct      = ffi.typeof("json_keyslice")

---@type ffi.cdata*  json_tok[?]
local tok_arena  = ffi.new(tok_arr_ct, TOK_INIT)
local tok_cap    = TOK_INIT
local tok_top    = 0 -- next free slot

local function tok_alloc()
	local idx = tok_top
	tok_top = idx + 1
	if tok_top > tok_cap then
		local newcap = tok_cap * 2
		local newarr = ffi.new(tok_arr_ct, newcap)
		ffi.copy(newarr, tok_arena, tok_cap * ffi.sizeof(tok_ct))
		tok_arena = newarr
		tok_cap   = newcap
	end
	return idx
end

-- ── key arena (append-only) ───────────────────────────────────────────────────
-- Stores ordered key strings for decoded objects (replaces per-object Lua table).
-- Never reset: slices from old decodes remain valid as long as the decoded object lives.

---@type string[]
local key_arena     = {}
local key_arena_top = 0

local ks_ct         = ffi.typeof("json_keyslice")

local function newKeySlice()
	local s = ks_ct()
	s.start = key_arena_top
	s.count = 0
	return s
end

local function pushKey(slice, key)
	local idx      = key_arena_top + 1
	key_arena[idx] = key
	key_arena_top  = idx
	slice.count    = slice.count + 1
end

-- ── weak stores (for encode-side metadata) ────────────────────────────────────

---@type table<table, string[] | json.KeySlice>
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
local function dq_replace(c) return dq_esc[c] or string.format("\\u%04x", string.byte(c)) end
local function sq_replace(c) return sq_esc[c] or string.format("\\u%04x", string.byte(c)) end

local dq_needs = ffi.new("uint8_t[256]")
for i = 0, 31 do dq_needs[i] = 1 end
dq_needs[34] = 1; dq_needs[92] = 1

local sq_needs = ffi.new("uint8_t[256]")
for i = 0, 31 do sq_needs[i] = 1 end
sq_needs[39] = 1; sq_needs[92] = 1

---@param tape  string.buffer
---@param s     string
---@param style json.StringStyle | nil
local function putString(tape, s, style)
	local len = #s
	local p   = cast(u8p, s)
	if style == "single" then
		tape:put("'")
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
	tape:put(closing); tape:put("]")
end

---@param tape   string.buffer
---@param t      json.Object
---@param indent string
---@param level  integer
local function putObject(tape, t, indent, level)
	local ks         = keyStore[t]
	local meta       = metaStore[t]
	local nextIndent = string.rep(indent, level + 1)

	if not ks then
		local keys = {}
		for k in pairs(t) do keys[#keys + 1] = k end
		table.sort(keys)
		local n = #keys
		if n == 0 then
			tape:put("{}"); return
		end
		tape:put("{\n")
		for i = 1, n do
			if i > 1 then tape:put(",\n") end
			tape:put(nextIndent); putString(tape, tostring(keys[i]), nil)
			tape:put(": "); putValue(tape, t[keys[i]], indent, level + 1, nil)
		end
		tape:put("\n"); tape:put(string.rep(indent, level)); tape:put("}")
		return
	end

	local isSlice = ffi.istype(ks_ct, ks)
	local nkeys   = isSlice and ks.count or #ks
	if nkeys == 0 then
		tape:put("{}"); return
	end

	if not meta then
		tape:put("{\n")
		if isSlice then
			local base = ks.start
			for i = 1, nkeys do
				if i > 1 then tape:put(",\n") end
				local k = key_arena[base + i]
				tape:put(nextIndent); putString(tape, k, nil)
				tape:put(": "); putValue(tape, t[k], indent, level + 1, nil)
			end
		else
			for i = 1, nkeys do
				if i > 1 then tape:put(",\n") end
				local k = ks[i]
				tape:put(nextIndent); putString(tape, k, nil)
				tape:put(": "); putValue(tape, t[k], indent, level + 1, nil)
			end
		end
		tape:put("\n"); tape:put(string.rep(indent, level)); tape:put("}")
		return
	end

	tape:put("{")
	if isSlice then
		local base = ks.start
		for i = 1, nkeys do
			if i > 1 then tape:put(",") end
			local k = key_arena[base + i]; local km = meta[k]
			tape:put((km and km.before) or " ")
			local ks2 = km and km.keyStyle
			if ks2 == "ident" then tape:put(k) else putString(tape, k, ks2) end
			tape:put((km and km.between) or ""); tape:put(":")
			tape:put((km and km.afterColon) or " ")
			putValue(tape, t[k], indent, level + 1, km and km.valueStyle)
			local av = km and km.afterValue; if av and av ~= "" then tape:put(av) end
		end
	else
		for i = 1, nkeys do
			if i > 1 then tape:put(",") end
			local k = ks[i]; local km = meta[k]
			tape:put((km and km.before) or " ")
			local ks2 = km and km.keyStyle
			if ks2 == "ident" then tape:put(k) else putString(tape, k, ks2) end
			tape:put((km and km.between) or ""); tape:put(":")
			tape:put((km and km.afterColon) or " ")
			putValue(tape, t[k], indent, level + 1, km and km.valueStyle)
			local av = km and km.afterValue; if av and av ~= "" then tape:put(av) end
		end
	end
	if meta.__trailingComma then tape:put(",") end
	tape:put(meta.__closingTrivia or " "); tape:put("}")
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
	local ks = keyStore[t]
	if not ks or ffi.istype(ks_ct, ks) then
		local arr = {}
		if ks then for i = 1, ks.count do arr[i] = key_arena[ks.start + i] end end
		keyStore[t] = arr; ks = arr
	end
	ks[#ks + 1] = key
end

---@param t   table
---@param key string
function json.removeField(t, key)
	t[key] = nil
	local ks = keyStore[t]
	if not ks or ffi.istype(ks_ct, ks) then return end
	for i, k in ipairs(ks) do
		if k == key then
			table.remove(ks, i); return
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
local src_ptr
---@type integer
local src_len
---@type string
local src_s

local ws_tab = ffi.new("uint8_t[256]")
ws_tab[32] = 1; ws_tab[9] = 1; ws_tab[10] = 1; ws_tab[13] = 1

local ident_tab = ffi.new("uint8_t[256]")
for i = 48, 57 do ident_tab[i] = 1 end
for i = 65, 90 do ident_tab[i] = 1 end
for i = 97, 122 do ident_tab[i] = 1 end
ident_tab[95] = 1; ident_tab[36] = 1

---@param pos integer 1-based
---@return integer    1-based
local function skipWS(pos)
	local i = pos - 1
	while i < src_len and ws_tab[src_ptr[i]] == 1 do i = i + 1 end
	return i + 1
end

---@param pos integer 1-based, sitting on '/'
---@param ts  integer trivia start
---@return string trivia
---@return integer    1-based after trivia
local function collectComments(pos, ts)
	while pos <= src_len do
		if src_ptr[pos - 1] ~= 47 then break end
		local b1 = src_ptr[pos]
		if b1 == 47 then
			local nl = C.memchr(src_ptr + pos + 1, 10, src_len - pos - 1)
			pos = nl ~= nil and (cast(u8p, nl) - src_ptr + 2) or (src_len + 1)
		elseif b1 == 42 then
			local p = src_ptr + pos + 1; local rem = src_len - pos - 1; local found = false
			while rem > 0 do
				local star = C.memchr(p, 42, rem); if star == nil then error("unterminated block comment") end
				local sp = cast(u8p, star); local off = sp - src_ptr
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
	return string.sub(src_s, ts, pos - 1), pos
end

---@param pos integer 1-based
---@return string|nil trivia
---@return integer    1-based after trivia
local function collectTrivia(pos)
	local npos = skipWS(pos)
	if npos <= src_len and src_ptr[npos - 1] == 47 then return collectComments(npos, pos) end
	if npos == pos then return nil, npos end
	return string.sub(src_s, pos, npos - 1), npos
end

---@type fun(pos:integer): integer, integer  -- returns (tok_idx, new_pos)
local parseValue -- forward decl

---@type table<integer,string>
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

-- Parse a quoted string into a token. Returns (tok_idx, new_pos).
---@param pos integer 1-based, pointing at opening quote
---@return integer tok_idx
---@return integer new_pos
local function parseString(pos)
	local quote = src_ptr[pos - 1]
	local i     = pos + 1
	local pq    = C.memchr(src_ptr + i - 1, quote, src_len - i + 1)
	if pq == nil then error("unterminated string") end
	local q_off   = cast(u8p, pq) - src_ptr
	local has_esc = C.memchr(src_ptr + i - 1, 92, q_off - (i - 1)) ~= nil

	local idx     = tok_alloc()
	local tok     = tok_arena[idx]
	tok.type      = TY_STRING
	tok.flags     = has_esc and 1 or 0
	tok.next      = 0
	tok.str_off   = i - 1 -- 0-based offset into src_s
	tok.str_len   = q_off - (i - 1)

	if not has_esc then
		return idx, q_off + 2
	end

	-- advance past the full escaped string
	local j = i
	while j <= src_len do
		local rem = src_len - j + 1; local base = src_ptr + j - 1
		local pbs = C.memchr(base, 92, rem); local pq2 = C.memchr(base, quote, rem)
		local bs_off = pbs ~= nil and (cast(u8p, pbs) - src_ptr) or src_len
		local q_off2 = pq2 ~= nil and (cast(u8p, pq2) - src_ptr) or src_len
		if q_off2 <= bs_off then
			tok.str_len = q_off2 - (i - 1) -- store full span including escapes
			return idx, q_off2 + 2
		end
		local esc = src_ptr[bs_off + 1]
		j = esc == 117 and bs_off + 7 or bs_off + 3
	end
	error("unterminated string")
end

-- Materialise a string token into a Lua string (allocates only when called).
---@param tok json.Token
---@return string
local function tokToString(tok)
	local off = tok.str_off + 1 -- 1-based start of content
	if tok.flags == 0 then
		return string.sub(src_s, off, off + tok.str_len - 1)
	end
	-- unescape: walk the raw span, replacing escape sequences
	local buf = {}
	local i   = off
	local lim = off + tok.str_len -- exclusive end (past last content byte)
	while i < lim do
		local rem    = lim - i
		local base   = src_ptr + i - 1
		local pbs    = C.memchr(base, 92, rem) -- backslash
		local bs_off = pbs ~= nil and (cast(u8p, pbs) - src_ptr) or (lim - 1)
		if bs_off >= lim - 1 then
			-- no more backslashes, copy remainder
			if i <= lim - 1 then buf[#buf + 1] = string.sub(src_s, i, lim - 1) end
			break
		end
		if bs_off > i - 1 then buf[#buf + 1] = string.sub(src_s, i, bs_off) end
		local esc = src_ptr[bs_off + 1]
		if esc == 117 then
			buf[#buf + 1] = string.char(tonumber(string.sub(src_s, bs_off + 2, bs_off + 5), 16))
			i = bs_off + 7
		elseif esc == 10 or esc == 13 then
			i = bs_off + 3
		else
			buf[#buf + 1] = escapeMap[esc] or string.char(esc); i = bs_off + 3
		end
	end
	return table.concat(buf)
end

---@param pos integer 1-based
---@return integer tok_idx
---@return integer new_pos
local function parseIdentifier(pos)
	local i = pos - 1
	local b = src_ptr[i]
	if not ((b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95 or b == 36) then
		error("invalid identifier at pos " .. pos)
	end
	i = i + 1
	while i < src_len and ident_tab[src_ptr[i]] == 1 do i = i + 1 end
	local idx   = tok_alloc()
	local tok   = tok_arena[idx]
	tok.type    = TY_STRING
	tok.flags   = 0
	tok.next    = 0
	tok.str_off = pos - 1 -- 0-based
	tok.str_len = i - (pos - 1)
	return idx, i + 1
end

---@param pos integer 1-based
---@return integer tok_idx
---@return integer new_pos
local function parseNumber(pos)
	local i = pos - 1; local neg = src_ptr[i] == 45
	if neg then i = i + 1 end
	local b = src_ptr[i]
	local idx = tok_alloc()
	local tok = tok_arena[idx]
	tok.next = 0
	if b >= 48 and b <= 57 then
		if b == 48 then
			local b2 = src_ptr[i + 1]; if b2 == 120 or b2 == 88 then goto slow end
		end
		local n = 0
		while i < src_len do
			b = src_ptr[i]; if b < 48 or b > 57 then break end; n = n * 10 + (b - 48); i = i + 1
		end
		if b ~= 46 and b ~= 101 and b ~= 69 then
			tok.type = TY_INT; tok.num = neg and -n or n; return idx, i + 1
		end
	end
	::slow::
	local numStr = string.match(src_s, "^-?0[xX]%x+", pos)
		or string.match(src_s, "^[+-]?%d+%.?%d*[eE]?[+-]?%d*", pos)
	local sub = string.sub(src_s, pos, pos + 8)
	local v
	if sub:sub(1, 8) == "Infinity" then
		v = huge; numStr = sub:sub(1, 8)
	elseif sub:sub(1, 9) == "+Infinity" then
		v = huge; numStr = sub:sub(1, 9)
	elseif sub:sub(1, 9) == "-Infinity" then
		v = -huge; numStr = sub:sub(1, 9)
	elseif sub:sub(1, 3) == "NaN" then
		v = 0 / 0; numStr = sub:sub(1, 3)
	else
		v = tonumber(numStr)
	end
	tok.type = TY_FLOAT; tok.num = v
	return idx, pos + #numStr
end

---@param pos integer 1-based, pointing at '['
---@return integer tok_idx
---@return integer new_pos
local function parseArray(pos)
	local idx          = tok_alloc()
	local tok          = tok_arena[idx]
	tok.type           = TY_ARRAY
	tok.next           = 0
	tok.child          = 0
	tok.count          = 0

	local trivia, npos = collectTrivia(pos + 1); pos = npos
	if src_ptr[pos - 1] == 93 then return idx, pos + 1 end

	local first_child = 0
	local prev_idx    = 0
	local count       = 0

	while true do
		local ci, npos2 = parseValue(pos); pos = npos2
		count = count + 1
		if first_child == 0 then first_child = ci end
		if prev_idx ~= 0 then tok_arena[prev_idx].next = ci end
		prev_idx = ci

		local _, npos3 = collectTrivia(pos); pos = npos3
		local c = src_ptr[pos - 1]
		if c == 93 then break end
		if c ~= 44 then error("expected ',' or ']'") end
		pos = pos + 1
		local _, npos4 = collectTrivia(pos); pos = npos4
		if src_ptr[pos - 1] == 93 then break end
	end

	tok_arena[idx].child = first_child
	tok_arena[idx].count = count
	return idx, pos + 1
end

---@param pos integer 1-based, pointing at '{'
---@return integer tok_idx
---@return integer new_pos
local function parseObject(pos)
	local idx          = tok_alloc()
	local tok          = tok_arena[idx]
	tok.type           = TY_OBJECT
	tok.next           = 0
	tok.child          = 0
	tok.count          = 0

	local trivia, npos = collectTrivia(pos + 1); pos = npos
	if src_ptr[pos - 1] == 125 then return idx, pos + 1 end

	local first_child = 0
	local prev_idx    = 0
	local count       = 0

	while true do
		-- key
		local c = src_ptr[pos - 1]
		local ki
		if c == 34 or c == 39 then
			ki, pos = parseString(pos)
		else
			ki, pos = parseIdentifier(pos)
		end

		local _, npos2 = collectTrivia(pos); pos = npos2
		if src_ptr[pos - 1] ~= 58 then error("expected ':'") end
		pos = pos + 1
		local _, npos3 = collectTrivia(pos); pos = npos3

		-- value
		local vi, npos4 = parseValue(pos); pos = npos4

		-- link: key.next -> value, value.next -> next key (set later)
		tok_arena[ki].next = vi
		count = count + 1
		if first_child == 0 then first_child = ki end
		if prev_idx ~= 0 then tok_arena[prev_idx].next = ki end
		prev_idx = vi -- next sibling chain continues from value

		local _, npos5 = collectTrivia(pos); pos = npos5
		c = src_ptr[pos - 1]
		if c == 125 then break end
		if c ~= 44 then error("expected ',' or '}'") end
		pos = pos + 1
		local _, npos6 = collectTrivia(pos); pos = npos6
		if src_ptr[pos - 1] == 125 then break end
	end

	tok_arena[idx].child = first_child
	tok_arena[idx].count = count
	return idx, pos + 1
end

parseValue = function(pos)
	local _, npos = collectTrivia(pos); pos = npos
	local c = src_ptr[pos - 1]
	if c == 34 or c == 39 then
		return parseString(pos)
	elseif c == 123 then
		return parseObject(pos)
	elseif c == 91 then
		return parseArray(pos)
	elseif c == 116 then
		local idx = tok_alloc(); tok_arena[idx].type = TY_TRUE; tok_arena[idx].next = 0
		return idx, pos + 4
	elseif c == 102 then
		local idx = tok_alloc(); tok_arena[idx].type = TY_FALSE; tok_arena[idx].next = 0
		return idx, pos + 5
	elseif c == 110 then
		local idx = tok_alloc(); tok_arena[idx].type = TY_NULL; tok_arena[idx].next = 0
		return idx, pos + 4
	else
		return parseNumber(pos)
	end
end

-- ── public API ────────────────────────────────────────────────────────────────

json.null = setmetatable({}, { __tostring = function() return "null" end })

-- Returns a doc table: { toks=tok_arena, src=src_s, root=root_idx }
-- The token arena is reused on the next decodeDocument call, so copy if you need persistence.
---@param s string
---@return json.Doc
function json.decodeDocument(s)
	tok_top       = 0
	src_s         = s
	src_len       = #s
	src_ptr       = cast(u8p, s)
	local root, _ = parseValue(1)
	return { toks = tok_arena, src = s, root = root }
end

-- Materialise a token into a plain Lua value (allocates strings/tables).
-- For hot paths prefer json.iter / json.get / json.str / json.num.
---@param doc  json.Doc
---@param idx  integer  token index
---@return json.Value
local function materialise(doc, idx)
	local tok = doc.toks[idx]
	local ty  = tok.type
	if ty == TY_NULL then
		return json.null
	elseif ty == TY_FALSE then
		return false
	elseif ty == TY_TRUE then
		return true
	elseif ty == TY_INT or ty == TY_FLOAT then
		return tok.num
	elseif ty == TY_STRING then
		-- re-bind src for tokToString
		src_s   = doc.src
		src_ptr = cast(u8p, src_s)
		src_len = #src_s
		return tokToString(tok)
	elseif ty == TY_ARRAY then
		local arr = {}
		local ci  = tok.child
		local i   = 0
		while ci ~= 0 do
			i = i + 1
			arr[i] = materialise(doc, ci)
			ci = doc.toks[ci].next
		end
		return arr
	elseif ty == TY_OBJECT then
		local obj     = {}
		local keys    = {}
		keyStore[obj] = keys
		local ki      = tok.child
		while ki ~= 0 do
			src_s           = doc.src; src_ptr = cast(u8p, src_s); src_len = #src_s
			local k         = tokToString(doc.toks[ki])
			local vi        = doc.toks[ki].next
			obj[k]          = materialise(doc, vi)
			keys[#keys + 1] = k
			ki              = doc.toks[vi].next
		end
		return obj
	end
	error("unknown token type " .. ty)
end

-- Iterate children of an array or object token.
-- For arrays:  yields (index, child_tok_idx)
-- For objects: yields (key_string, value_tok_idx)
---@param doc json.Doc
---@param idx integer  token index of array or object
---@return fun(): (string|integer|nil), integer|nil
function json.iter(doc, idx)
	local tok = doc.toks[idx]
	local ty  = tok.type
	if ty == TY_ARRAY then
		local ci = tok.child
		local i  = 0
		return function()
			if ci == 0 then return nil end
			i         = i + 1
			local cur = ci
			ci        = doc.toks[ci].next
			return i, cur
		end
	elseif ty == TY_OBJECT then
		local ki = tok.child
		src_s = doc.src; src_ptr = cast(u8p, src_s); src_len = #src_s
		return function()
			if ki == 0 then return nil end
			local k  = tokToString(doc.toks[ki])
			local vi = doc.toks[ki].next
			ki       = doc.toks[vi].next
			return k, vi
		end
	end
	return function() return nil end
end

-- Get a child token by key (object) or index (array). Returns token index or nil.
---@param doc json.Doc
---@param idx integer
---@param key string | integer
---@return integer | nil
function json.get(doc, idx, key)
	local tok = doc.toks[idx]
	local ty  = tok.type
	if ty == TY_ARRAY then
		local ci = tok.child; local i = 0
		while ci ~= 0 do
			i = i + 1
			if i == key then return ci end
			ci = doc.toks[ci].next
		end
	elseif ty == TY_OBJECT then
		src_s = doc.src; src_ptr = cast(u8p, src_s); src_len = #src_s
		local ki = tok.child
		while ki ~= 0 do
			if tokToString(doc.toks[ki]) == key then return doc.toks[ki].next end
			ki = doc.toks[doc.toks[ki].next].next
		end
	end
	return nil
end

-- Get the Lua string value of a string token.
---@param doc json.Doc
---@param idx integer
---@return string
function json.str(doc, idx)
	src_s = doc.src; src_ptr = cast(u8p, src_s); src_len = #src_s
	return tokToString(doc.toks[idx])
end

-- Get the numeric value of a number token.
---@param doc json.Doc
---@param idx integer
---@return number
function json.num(doc, idx)
	return doc.toks[idx].num
end

-- Get the type name of a token.
---@param doc json.Doc
---@param idx integer
---@return "null"|"boolean"|"number"|"string"|"array"|"object"
function json.type(doc, idx)
	local ty = doc.toks[idx].type
	if ty == TY_NULL then
		return "null"
	elseif ty == TY_FALSE or ty == TY_TRUE then
		return "boolean"
	elseif ty == TY_INT or ty == TY_FLOAT then
		return "number"
	elseif ty == TY_STRING then
		return "string"
	elseif ty == TY_ARRAY then
		return "array"
	else
		return "object"
	end
end

-- Materialise the full document into Lua tables (old behaviour, allocates).
---@param doc json.Doc
---@param doc json.Doc
---@return json.Value
function json.materialise(doc)
	return materialise(doc, doc.root)
end

-- Decode JSON string into plain Lua tables (allocating).
---@param s string
---@return json.Value
function json.decode(s)
	local doc = json.decodeDocument(s)
	return materialise(doc, doc.root)
end

-- Encode a json.Doc back to a JSON string (materialises then encodes).
---@param doc json.Doc
---@return string
function json.encodeDocument(doc)
	return json.encode(materialise(doc, doc.root))
end

return json
