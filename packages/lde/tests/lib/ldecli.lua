local process = require("process")
local env = require("env")

local ldePath = assert(env.execPath())

---@param args string[]
---@param cwd string?
---@param opts process.Options?
---@return boolean, string?
return function(args, cwd, opts)
	local code, stdout, stderr = process.exec(ldePath, args, { cwd = cwd, stdin = opts and opts.stdin })
	return code == 0, stdout or stderr
end
