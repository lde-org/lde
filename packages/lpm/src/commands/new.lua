local fs = require("fs")
local ansi = require("ansi")
local path = require("path")
local env = require("env")

local lpm = require("lpm-core")

---@param args clap.Args
local function new(args)
	local name = assert(args:pop(), "Usage: lpm new <name>")

	if fs.exists(name) then
		error("Directory " .. name .. " already exists")
	end

	local parent = path.dirname(name)
	if parent ~= "" and parent ~= "." and not fs.isdir(parent) then
		error("Cannot create '" .. name .. "': parent directory does not exist")
	end

	fs.mkdir(name)
	ansi.printf("{green}Created directory: %s", name)

	lpm.Package.init(path.join(env.cwd(), name))
end

return new
