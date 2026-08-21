--- Teal compiler, built on the shared compiler guest machinery.
local fs = require("fs")
local path = require("path")

---@type lde.Compiler
local teal = require("lde-core.compiler").new({
	name = "Teal",
	packageName = "tl",
	loadExpr = 'return require("tl")',
	extension = ".tl",
	hasSourceFilter = function(rel) return not rel:match("%.d%.tl$") end,
	-- Runs inside the compiler guest: the tl module and the shared env stay
	-- loaded in that state across compiles. Type errors never block codegen
	-- (only syntax errors do); `tl check` remains the strict tool.
	driver = [[
		local source, filename = ...
		local tl = require("tl")
		if not _lde_tl_env then
			_lde_tl_env = tl.init_env(false, false, "5.1")
		end
		local result = tl.process_string(source, false, _lde_tl_env, filename)
		if not result.ast then
			local msgs = {}
			for _, e in ipairs(result.syntax_errors or {}) do
				msgs[#msgs + 1] = string.format("%s:%d:%d: %s", e.filename or filename, e.y, e.x, e.msg)
			end
			return { err = table.concat(msgs, "\n") }
		end
		return { code = tl.generate(result.ast, _lde_tl_env.defaults.gen_target) }
	]],
	matchSource = function(rel)
		return rel:match("%.tl$") ~= nil and not rel:match("%.d%.tl$")
	end,
	-- Parenthesized: gsub returns a second (count) value that would leak into
	-- path.join's varargs.
	outRel = function(rel) return (rel:gsub("%.tl$", ".lua")) end,
	writeExtras = function(outDir, rel, source)
		-- Keep the .tl source alongside the compiled .lua so `tl check` can
		-- resolve this package's modules with full type info (see compileDir).
		fs.write(path.join(outDir, rel), source)
	end,
})

return teal
