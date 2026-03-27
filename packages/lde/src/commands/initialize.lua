local env = require("env")

local lde = require("lde-core")

---@param args clap.Args
local function init(args)
	local path = args:pop() or env.cwd()
	lde.Package.init(path)
end

return init
