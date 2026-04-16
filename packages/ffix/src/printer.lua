---@class ffix.c.Printer
local Printer = {}
Printer.__index = Printer

function Printer.new()
	return setmetatable({}, Printer)
end

---@param t ffix.c.Parser.Type
---@param name string?
---@return string
function Printer:typedName(t, name)
	local parts = {}
	for _, q in ipairs(t.qualifiers) do parts[#parts + 1] = q end
	parts[#parts + 1] = t.name
	local base = table.concat(parts, " ")
	local stars = string.rep("*", t.pointer)
	if t.pointer > 0 then
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

---@param node ffix.c.Parser.Node
---@return string
function Printer:node(node)
	local k = node.kind

	if k == "typedef_alias" then
		return "typedef " .. self:typedName(node.type, node.name) .. ";"

	elseif k == "typedef_struct" then
		local lines = { "typedef struct" .. (node.tag and (" " .. node.tag) or "") .. " {" }
		for _, f in ipairs(node.fields) do
			lines[#lines + 1] = "\t" .. self:typedName(f.type, f.name) .. ";"
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
