---@class ffix.c.Tokenizer
---@field private ptr number
---@field private len number
---@field private src string
local Tokenizer = {}
Tokenizer.__index = Tokenizer

function Tokenizer.new()
	return setmetatable({}, Tokenizer)
end

---@param pattern string
function Tokenizer:skip(pattern)
	local start, finish = string.find(self.src, pattern, self.ptr)
	if start then
		self.ptr = finish + 1
		return true
	end
end

---@param pattern string
---@return string?
function Tokenizer:consume(pattern)
	local start, finish, match = string.find(self.src, pattern, self.ptr)
	if start then
		self.ptr = finish + 1
		return match or true
	end
end

function Tokenizer:skipWhitespace()
	return self:skip("^%s+")
end

function Tokenizer:skipComments()
	return self:skip("^//[^\n]+\n") or self:skip("^#[^\n]+\n")
end

---@class ffix.c.Tokenizer.Token.Ident
---@field variant "ident"
---@field ident string

---@class ffix.c.Tokenizer.Token.Number
---@field variant "number"
---@field number number

---@class ffix.c.Tokenizer.Token.String
---@field variant "string"
---@field number string

---@class ffix.c.Tokenizer.Token.Special
---@field variant string

---@alias ffix.c.Tokenizer.Token
--- | ffix.c.Tokenizer.Token.Ident
--- | ffix.c.Tokenizer.Token.String
--- | ffix.c.Tokenizer.Token.Number
--- | ffix.c.Tokenizer.Token.Special

---@type table<string, true>
local special = {}

for _, s in ipairs({
	"typedef", "{", "}", "[", "]", "(", ")", ",", ".", ";", ":", "<", ">", "*", "&", "~", "...", "::",
	"struct", "enum", "union", "const", "restrict", "extern", "static", "volatile",
	"unsigned", "signed", "void", "char", "short", "int", "long", "float", "double"
}) do
	special[s] = true
end

---@return ffix.c.Tokenizer.Token?
function Tokenizer:next()
	local ident = self:consume("^([%a_][%w_]*)")
	if ident then
		if special[ident] then
			return { variant = ident }
		end

		return { variant = "ident", ident = ident }
	end

	local dec = self:consume("^(%d+%.%d+)")
	if dec then
		return { variant = "number", number = tonumber(dec) }
	end

	local hex = self:consume("^0x([%x]+)")
	if hex then
		return { variant = "number", number = tonumber(hex, 16) }
	end

	local int = self:consume("^(%d+)[uUlL]*")
	if int then
		return { variant = "number", number = tonumber(int) }
	end

	local str = self:consume("^\"([^\"]+)\"")
	if str then
		return { variant = "string", string = str }
	end

	local three = string.sub(self.src, self.ptr, self.ptr + 2)
	if special[three] then
		self.ptr = self.ptr + 3
		return { variant = three }
	end

	local two = string.sub(self.src, self.ptr, self.ptr + 1)
	if special[two] then
		self.ptr = self.ptr + 2
		return { variant = two }
	end

	local one = string.sub(self.src, self.ptr, self.ptr)
	if special[one] then
		self.ptr = self.ptr + 1
		return { variant = one }
	end
end

---@param src string
function Tokenizer:tokenize(src)
	self.ptr = 1
	self.len = #src
	self.src = src

	---@type ffix.c.Tokenizer.Token[]
	local tokens = {}

	while true do
		while self:skipWhitespace() or self:skipComments() do end
		if self.ptr > self.len then break end

		local tok = self:next()
		if not tok then
			error("Unrecognized character: " .. string.sub(self.src, self.ptr, self.ptr))
		end

		tokens[#tokens + 1] = tok
	end

	return tokens
end

return Tokenizer
