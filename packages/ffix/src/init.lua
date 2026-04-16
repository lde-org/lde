local ffi = require("ffi")

local ffix = {}

local Tokenizer = require("ffix.tokenizer")
local Parser = require("ffix.parser")
local Printer = require("ffix.printer")

---@class ffix.Context
---@field private pfx string
---@field private names table<string, string>  -- original -> prefixed
local Context = {}
Context.__index = Context

---@param t ffix.c.Parser.Type
---@return ffix.c.Parser.Type
function Context:rewriteType(t)
	local name = t.name

	local kw, base = name:match("^(%a+) ([%a_][%w_]*)$")
	if kw == "struct" or kw == "enum" or kw == "union" then
		name = kw .. " " .. (self.names[base] or base)
	else
		name = self.names[name] or name
	end

	return { qualifiers = t.qualifiers, name = name, pointer = t.pointer, reference = t.reference }
end

---@param params ffix.c.Parser.Param[]
---@return ffix.c.Parser.Param[]
function Context:rewriteParams(params)
	local out = {}
	for _, p in ipairs(params) do
		out[#out + 1] = { type = self:rewriteType(p.type), name = p.name }
	end

	return out
end

---@format disable-next
---@private
---@param node ffix.c.Parser.Node
---@return ffix.c.Parser.Node
function Context:rewriteNode(node)
	local k = node.kind
	local renamed = self.names[node.name] or node.name

	if k == "typedef_alias" then
		return { kind = k, name = renamed, type = self:rewriteType(node.type) }
	elseif k == "typedef_struct" then
		local fields = {}
		for _, f in ipairs(node.fields) do
			fields[#fields + 1] = { type = self:rewriteType(f.type), name = f.name, array_size = f.array_size, attrs = f.attrs }
		end

		return { kind = k, name = renamed, tag = node.tag and (self.names[node.tag] or node.tag), fields = fields, attrs = node.attrs }
	elseif k == "typedef_enum" then
		return { kind = k, name = renamed, tag = node.tag and (self.names[node.tag] or node.tag), variants = node.variants }
	elseif k == "typedef_fnptr" then
		return { kind = k, name = renamed, ret = self:rewriteType(node.ret), params = self:rewriteParams(node.params) }
	elseif k == "fn_decl" then
		return { kind = k, name = renamed, asm_name = node.name, ret = self:rewriteType(node.ret), params = self:rewriteParams(node.params), attrs = node.attrs }
	elseif k == "extern_var" then
		return { kind = k, name = renamed, asm_name = node.name, type = self:rewriteType(node.type) }
	end

	error("unknown node kind: " .. tostring(node.kind))
end

---@param code string
function Context:cdef(code)
	local tokens = Tokenizer.new():tokenize(code)
	local ok, nodes = Parser.new():parse(tokens)
	if not ok then error("ffix: failed to parse cdef block") end

	-- first pass: register all declared names
	for _, node in ipairs(nodes) do
		if node.name then
			self.names[node.name] = self.pfx .. "_" .. node.name
		end
	end

	-- second pass: rewrite and emit
	local rewritten = {}
	for _, node in ipairs(nodes) do
		rewritten[#rewritten + 1] = self:rewriteNode(node)
	end

	ffi.cdef(Printer.new():print(rewritten))
end

---@param typename string
function Context:new(typename, ...)
	return ffi.new(self.names[typename] or typename, ...)
end

---@param typename string
function Context:cast(typename, ...)
	local base, tail = typename:match("^([%a_][%w_]*)(.*)")
	if base and self.names[base] then typename = self.names[base] .. tail end
	return ffi.cast(typename, ...)
end

---@param typename string
function Context:typeof(typename)
	return ffi.typeof(self.names[typename] or typename)
end

---@param typename string
function Context:sizeof(typename)
	return ffi.sizeof(self.names[typename] or typename)
end

---@param lib string
function Context:load(lib)
	return ffi.load(lib)
end

---@param pfx string
function ffix.context(pfx)
	return setmetatable({ pfx = pfx, names = {} }, Context)
end

return ffix
