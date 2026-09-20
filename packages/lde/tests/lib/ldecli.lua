local process = require("process")
local env = require("env")

local ldePath = assert(env.execPath())

---@param args string[]
---@param cwd string?
---@param opts process.Options?
---@return boolean ok
---@return string out # stdout + stderr: what the user sees
---@return string stdout # for assertions about a specific stream
---@return string stderr
return function(args, cwd, opts)
	local code, stdout, stderr = process.exec(ldePath, args, { cwd = cwd, stdin = opts and opts.stdin })
	stdout, stderr = stdout or "", stderr or ""
	return code == 0, stdout .. stderr, stdout, stderr
end
