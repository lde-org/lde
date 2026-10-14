const fs = require("fs")
const path = require("path")

---@type lde.Compiler
const teal = require("lde-core.compiler").new({
	name = "Teal",
	packageName = "tl",
	loadExpr = 'return require("tl")',
	extension = ".tl",
	hasSourceFilter = function(rel) return not rel:match("%.d%.tl$") end,
	-- tl stays loaded in the guest, but init_env must be fresh per compile (reuse returns the previous result).
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
	-- Parenthesized: gsub's count would leak into path.join's varargs.
	outRel = function(rel) return (rel:gsub("%.tl$", ".lua")) end,
	writeExtras = function(outDir, rel, source)
		fs.write(path.join(outDir, rel), source)
	end,
})

return teal
