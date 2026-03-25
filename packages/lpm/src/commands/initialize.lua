local env = require("env")

local lpm = require("lpm-core")

---@param args clap.Args
local function init(args)
	local path = args:pop() or env.cwd()
	lpm.Package.init(path)
end

return init
