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
	-- Runs inside the compiler guest: the tl module stays loaded in that state
	-- across compiles, but the env is created fresh per compile — reusing one
	-- env makes tl.process_string return the previous result (stale output).
	-- Type errors never block codegen (only syntax errors do); `tl check`
	-- remains the strict tool.
	driver = [[
		local source, filename = ...
		local tl = require("tl")
		local env = tl.init_env(false, false, "5.1")
		local result = tl.process_string(source, false, env, filename)
		if not result.ast then
			local msgs = {}
			for _, e in ipairs(result.syntax_errors or {}) do
				msgs[#msgs + 1] = string.format("%s:%d:%d: %s", e.filename or filename, e.y, e.x, e.msg)
			end
			return { err = table.concat(msgs, "\n") }
		end
		return { code = tl.generate(result.ast, env.defaults.gen_target) }
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
