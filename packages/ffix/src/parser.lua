---@class ffix.c.Parser
---@field private ptr number
---@field private tokens ffix.c.Tokenizer.Token[]
local Parser = {}
Parser.__index = Parser

---@class ffix.c.Parser.Type
---@field qualifiers string[]
---@field name string
---@field pointer number

---@class ffix.c.Parser.Field
---@field type ffix.c.Parser.Type
---@field name string

---@class ffix.c.Parser.Variant
---@field name string

---@class ffix.c.Parser.Param
---@field type ffix.c.Parser.Type
---@field name string?

---@class ffix.c.Parser.Node.TypedefAlias
---@field kind "typedef_alias"
---@field type ffix.c.Parser.Type
---@field name string

---@class ffix.c.Parser.Node.TypedefStruct
---@field kind "typedef_struct"
---@field tag string?
---@field fields ffix.c.Parser.Field[]
---@field name string

---@class ffix.c.Parser.Node.TypedefEnum
---@field kind "typedef_enum"
---@field tag string?
---@field variants ffix.c.Parser.Variant[]
---@field name string

---@class ffix.c.Parser.Node.TypedefFnPtr
---@field kind "typedef_fnptr"
---@field ret ffix.c.Parser.Type
---@field name string
---@field params ffix.c.Parser.Param[]

---@class ffix.c.Parser.Node.FnDecl
---@field kind "fn_decl"
---@field ret ffix.c.Parser.Type
---@field name string
---@field params ffix.c.Parser.Param[]
---@field asm_name string?

---@class ffix.c.Parser.Node.ExternVar
---@field kind "extern_var"
---@field type ffix.c.Parser.Type
---@field name string
---@field asm_name string?

---@alias ffix.c.Parser.Node
--- | ffix.c.Parser.Node.TypedefAlias
--- | ffix.c.Parser.Node.TypedefStruct
--- | ffix.c.Parser.Node.TypedefEnum
--- | ffix.c.Parser.Node.TypedefFnPtr
--- | ffix.c.Parser.Node.FnDecl
--- | ffix.c.Parser.Node.ExternVar

function Parser.new()
	return setmetatable({}, Parser)
end

---@return ffix.c.Tokenizer.Token?
function Parser:peek()
	return self.tokens[self.ptr]
end

---@return ffix.c.Tokenizer.Token?
function Parser:advance()
	local tok = self.tokens[self.ptr]
	if tok then self.ptr = self.ptr + 1 end
	return tok
end

---@param variant string
---@return ffix.c.Tokenizer.Token?
function Parser:consume(variant)
	local tok = self.tokens[self.ptr]
	if tok and tok.variant == variant then
		self.ptr = self.ptr + 1
		return tok
	end
end

---@param variant string
---@return ffix.c.Tokenizer.Token
function Parser:expect(variant)
	local tok = self:consume(variant)
	if not tok then
		local got = self.tokens[self.ptr]
		error("expected '" .. variant .. "' got '" .. (got and got.variant or "EOF") .. "'")
	end
	return tok
end

local type_quals = { const = true, volatile = true, restrict = true, unsigned = true, signed = true, long = true, short = true }
local base_types = { void = true, char = true, int = true, float = true, double = true }

---@return ffix.c.Parser.Type
function Parser:parseType()
	local quals = {}
	local name

	while true do
		local tok = self:peek()
		if not tok then break end

		if type_quals[tok.variant] then
			quals[#quals + 1] = tok.variant
			self:advance()
		elseif base_types[tok.variant] then
			name = tok.variant
			self:advance()
			break
		elseif tok.variant == "struct" or tok.variant == "enum" or tok.variant == "union" then
			local kw = tok.variant
			self:advance()
			local tag = self:expect("ident")
			name = kw .. " " .. tag.ident
			break
		elseif tok.variant == "ident" then
			name = tok.ident
			self:advance()
			break
		else
			break
		end
	end

	-- trailing const/volatile after name
	while true do
		local tok = self:peek()
		if tok and type_quals[tok.variant] then
			quals[#quals + 1] = tok.variant
			self:advance()
		else
			break
		end
	end

	if not name then
		-- qualifiers only (e.g. "unsigned" as shorthand for "unsigned int")
		if #quals > 0 then
			name = quals[#quals]
			quals[#quals] = nil
		else
			error("expected type")
		end
	end

	local pointer = 0
	while self:consume("*") do
		pointer = pointer + 1
		-- eat pointer-level qualifiers
		while true do
			local tok = self:peek()
			if tok and (tok.variant == "const" or tok.variant == "volatile" or tok.variant == "restrict") then
				self:advance()
			else
				break
			end
		end
	end

	return { qualifiers = quals, name = name, pointer = pointer }
end

---@return ffix.c.Parser.Field[]
function Parser:parseFields()
	local fields = {}
	while not self:consume("}") do
		local ftype = self:parseType()
		local name = self:expect("ident")
		if self:consume("[") then
			while not self:consume("]") do self:advance() end
		end
		self:expect(";")
		fields[#fields + 1] = { type = ftype, name = name.ident }
	end
	return fields
end

---@return ffix.c.Parser.Variant[]
function Parser:parseVariants()
	local variants = {}
	while not self:consume("}") do
		local name = self:expect("ident")
		self:consume(",")
		variants[#variants + 1] = { name = name.ident }
	end
	return variants
end

---@return ffix.c.Parser.Param[]
function Parser:parseParams()
	self:expect("(")
	local params = {}
	if self:consume(")") then return params end
	-- (void) means no params, but (void *) is a real param — peek ahead
	if self.tokens[self.ptr] and self.tokens[self.ptr].variant == "void"
		and self.tokens[self.ptr + 1] and self.tokens[self.ptr + 1].variant == ")" then
		self.ptr = self.ptr + 2
		return params
	end
	while true do
		if self:consume("...") then
			self:consume(")")
			break
		end
		local ptype = self:parseType()
		local name_tok = self:consume("ident")
		params[#params + 1] = { type = ptype, name = name_tok and name_tok.ident }
		if self:consume(")") then break end
		self:expect(",")
	end
	return params
end

---@return string?
function Parser:parseAsmName()
	local tok = self:peek()
	if tok and tok.variant == "ident" and (tok.ident == "__asm__" or tok.ident == "asm") then
		self:advance()
		self:expect("(")
		local str = self:expect("string")
		self:expect(")")
		return str.string
	end
end

---@return ffix.c.Parser.Node
function Parser:parseDecl()
	if self:consume("typedef") then
		local kw = self:peek()

		if kw and (kw.variant == "struct" or kw.variant == "union") then
			self:advance()
			local tag_tok = self:consume("ident")
			self:expect("{")
			local fields = self:parseFields()
			local name = self:expect("ident")
			self:expect(";")
			return { kind = "typedef_struct", tag = tag_tok and tag_tok.ident, fields = fields, name = name.ident }
		end

		if kw and kw.variant == "enum" then
			self:advance()
			local tag_tok = self:consume("ident")
			self:expect("{")
			local variants = self:parseVariants()
			local name = self:expect("ident")
			self:expect(";")
			return { kind = "typedef_enum", tag = tag_tok and tag_tok.ident, variants = variants, name = name.ident }
		end

		local ret = self:parseType()

		-- function pointer: typedef ret (*name)(params);
		if self:consume("(") then
			self:expect("*")
			local name = self:expect("ident")
			self:expect(")")
			local params = self:parseParams()
			self:expect(";")
			return { kind = "typedef_fnptr", ret = ret, name = name.ident, params = params }
		end

		local name = self:expect("ident")
		self:expect(";")
		return { kind = "typedef_alias", type = ret, name = name.ident }
	end

	if self:consume("extern") then
		local type = self:parseType()
		local name = self:expect("ident")
		local asm_name = self:parseAsmName()
		self:expect(";")
		return { kind = "extern_var", type = type, name = name.ident, asm_name = asm_name }
	end

	local ret = self:parseType()
	local name = self:expect("ident")
	local params = self:parseParams()
	local asm_name = self:parseAsmName()
	self:expect(";")

	return { kind = "fn_decl", ret = ret, name = name.ident, params = params, asm_name = asm_name }
end

---@param tokens ffix.c.Tokenizer.Token[]
---@return boolean, ffix.c.Parser.Node[]
function Parser:parse(tokens)
	self.ptr = 1
	self.tokens = tokens

	local nodes = {}
	local ok, err = pcall(function()
		while self.ptr <= #self.tokens do
			nodes[#nodes + 1] = self:parseDecl()
		end
	end)

	if not ok then
		return false, nodes
	end

	return true, nodes
end

return Parser
