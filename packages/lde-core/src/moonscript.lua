--- Moonscript compiler, built on the shared compiler guest machinery.
---@type lde.Compiler
local moonscript = require("lde-core.compiler").new({
	name = "Moonscript",
	packageName = "moonscript",
	loadExpr = 'return require("moonscript.base")',
	extension = ".moon",
	-- Runs inside the compiler guest: to_lua returns the compiled Lua or a
	-- formatted error.
	driver = [[
		local source = ...
		local base = require("moonscript.base")
		local code, err = base.to_lua(source)
		if not code then
			return { err = err }
		end
		return { code = code }
	]],
	matchSource = function(rel) return rel:match("%.moon$") ~= nil end,
	-- Parenthesized: gsub returns a second (count) value that would leak into
	-- path.join's varargs.
	outRel = function(rel) return (rel:gsub("%.moon$", ".lua")) end,
})

return moonscript
