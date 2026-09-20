local process = require("process")
local env = require("env")

local ldePath = assert(env.execPath())

---@param args string[]
---@param cwd string?
---@param opts process.Options?
---@return boolean ok
---@return string? out # stdout when the command wrote any, else stderr
---@return string? stderr
return function(args, cwd, opts)
	local code, stdout, stderr = process.exec(ldePath, args, { cwd = cwd, stdin = opts and opts.stdin })
	return code == 0, stdout or stderr, stderr
end
