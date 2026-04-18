---@class ffix.c.Printer
local Printer = {}
Printer.__index = Printer

function Printer.new()
	return setmetatable({}, Printer)
end

---@param t ffix.c.Parser.Type
---@return string
function Printer:inlineType(t)
	local kw = t.inline_kind
	local tag_part = t.inline_tag and (" " .. t.inline_tag) or ""
	local attr_str = (t.inline_attrs and #t.inline_attrs > 0) and (" " .. self:attrsStr(t.inline_attrs)) or ""
	if kw == "enum" then
		local parts = {}
		for _, v in ipairs(t.inline_variants) do parts[#parts + 1] = v.name end
		return "enum" .. tag_part .. " { " .. table.concat(parts, ", ") .. " }"
	else
		local parts = {}
		for _, f in ipairs(t.inline_fields) do
			local arr = f.array_size and ("[" .. f.array_size .. "]") or ""
			local fattr = (f.attrs and #f.attrs > 0) and (" " .. self:attrsStr(f.attrs)) or ""
			parts[#parts + 1] = self:typedName(f.type, f.name) .. arr .. fattr .. ";"
		end
		return kw .. tag_part .. attr_str .. " { " .. table.concat(parts, " ") .. " }"
	end
end

---@param t ffix.c.Parser.Type
---@param name string?
---@return string
function Printer:typedName(t, name)
	local base
	if t.inline_kind then
		base = self:inlineType(t)
	else
		local parts = {}
		for _, q in ipairs(t.qualifiers) do parts[#parts + 1] = q end
		parts[#parts + 1] = t.name
		base = table.concat(parts, " ")
	end
	local stars = string.rep("*", t.pointer) .. (t.reference and "&" or "")
	if t.pointer > 0 or t.reference then
		return base .. " " .. stars .. (name or "")
	end
	return name and (base .. " " .. name) or base
end

---@param params ffix.c.Parser.Param[]
---@return string
function Printer:paramList(params)
	if #params == 0 then return "void" end
	local parts = {}
	for _, p in ipairs(params) do
		parts[#parts + 1] = self:typedName(p.type, p.name)
	end
	return table.concat(parts, ", ")
end

---@param attrs ffix.c.Attr[]
---@return string
function Printer:attrsStr(attrs)
	local parts = {}
	for _, a in ipairs(attrs) do
		parts[#parts + 1] = a.args and (a.name .. "(" .. a.args .. ")") or a.name
	end
	return "__attribute__((" .. table.concat(parts, ", ") .. "))"
end

---@param node ffix.c.Parser.Node
---@return string
function Printer:node(node)
	local k = node.kind

	if k == "typedef_alias" then
		return "typedef " .. self:typedName(node.type, node.name) .. ";"

	elseif k == "typedef_struct" then
		local attr_str = (node.attrs and #node.attrs > 0) and (" " .. self:attrsStr(node.attrs)) or ""
		local lines = { "typedef struct" .. (node.tag and (" " .. node.tag) or "") .. attr_str .. " {" }
		for _, f in ipairs(node.fields) do
			local arr = f.array_size and ("[" .. f.array_size .. "]") or ""
			local fattr = (f.attrs and #f.attrs > 0) and (" " .. self:attrsStr(f.attrs)) or ""
			lines[#lines + 1] = "\t" .. self:typedName(f.type, f.name) .. arr .. fattr .. ";"
		end
		lines[#lines + 1] = "} " .. node.name .. ";"
		return table.concat(lines, "\n")

	elseif k == "typedef_enum" then
		local lines = { "typedef enum" .. (node.tag and (" " .. node.tag) or "") .. " {" }
		for _, v in ipairs(node.variants) do
			lines[#lines + 1] = "\t" .. v.name .. ","
		end
		lines[#lines + 1] = "} " .. node.name .. ";"
		return table.concat(lines, "\n")

	elseif k == "typedef_fnptr" then
		return "typedef " .. self:typedName(node.ret, "(*" .. node.name .. ")") .. "("
			.. self:paramList(node.params) .. ");"

	elseif k == "fn_decl" then
		local s = self:typedName(node.ret, node.name) .. "(" .. self:paramList(node.params) .. ")"
		if node.asm_name then s = s .. " __asm__(\"" .. node.asm_name .. "\")" end
		if node.attrs and #node.attrs > 0 then s = s .. " " .. self:attrsStr(node.attrs) end
		return s .. ";"

	elseif k == "extern_var" then
		local s = "extern " .. self:typedName(node.type, node.name)
		if node.asm_name then s = s .. " __asm__(\"" .. node.asm_name .. "\")" end
		return s .. ";"
	end

	error("unknown node kind: " .. tostring(node.kind))
end

---@param nodes ffix.c.Parser.Node[]
---@return string
function Printer:print(nodes)
	local parts = {}
	for _, n in ipairs(nodes) do
		parts[#parts + 1] = self:node(n)
	end
	return table.concat(parts, "\n")
end

return Printer
