-- disable formatting with conform
local present, conf = pcall(require, "conform")
if present and conf.formatters_by_ft then
	conf.formatters_by_ft.lua = nil
end

-- enable formatting with LuaLS
vim.lsp.config("lua_ls", {
	settings = {
		Lua = { format = { enable = true } },
	},
})
vim.api.nvim_create_autocmd("BufWritePre", {
	pattern = "*",
	callback = function()
		if vim.o.ft == "lua" then
			vim.lsp.buf.format()
		end
	end
})
