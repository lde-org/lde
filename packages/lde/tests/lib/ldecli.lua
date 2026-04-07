local process = require("process2")
local env = require("env")

local ldePath = assert(env.execPath())

---@param args string[]
---@param cwd string?
---@return boolean, string?
return function(args, cwd)
	local code, stdout, stderr = process.exec(ldePath, args, { cwd = cwd })
	return code == 0, stdout or stderr
end
