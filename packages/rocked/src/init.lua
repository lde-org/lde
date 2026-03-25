local rocked = {}

---@class rocked.raw.Description
---@field summary string
---@field detailed string
---@field homepage string
---@field license string

---@alias rocked.raw.builtin.Build.Source
--- | string
--- | { sources: string[], libraries: string[]?, incdirs: string[]?, libdirs: string[]? }

---@class rocked.raw.builtin.Build.Install
---@field lua table<string, string>?
---@field bin table<string, string>?
---@field lib table<string, string>?
---@field conf table<string, string>?

---@class rocked.raw.builtin.Build
---@field type "builtin"
---@field modules table<string, rocked.raw.builtin.Build.Source>
---@field install rocked.raw.builtin.Build.Install?
---@field copy_directories string[]?

---@class rocked.raw.module.Build
---@field type "module"
---@field modules table<string, string>

---@alias rocked.raw.Build
--- | rocked.raw.builtin.Build
--- | rocked.raw.module.Build

---@class rocked.raw.Output
---@field version string
---@field package string
---@field description rocked.raw.Description
---@field source { url: string }
---@field dependencies string[]
---@field build rocked.raw.Build

-- Things we'll provide to the rockspec sandbox
local baseChunkEnv = {
	pairs = pairs,
	ipairs = ipairs,
	next = next
}

---@overload fun(spec: string): false, string?
---@overload fun(spec: string): true, rocked.raw.Output
function rocked.raw(spec)
	local unsafeChunk, err = loadstring(spec, "t")
	if not unsafeChunk then
		return false, err
	end

	local oh, om, oc = debug.gethook()
	debug.sethook(function() error("Rockspec took too long to run") end, "", 1e7)

	local chunkEnv = setmetatable({}, { __index = baseChunkEnv })
	local chunk = setfenv(unsafeChunk, chunkEnv)

	-- Debug hooks aren't guaranteed to run with JIT on, also it's safer this way
	jit.off(chunk)

	local ok, out = pcall(chunk)

	debug.sethook(oh, om, oc)

	if not ok then
		return false, out
	end

	return true, chunkEnv
end

local validRockTypes = {
	["builtin"] = true,
	["module"] = true
}

---@overload fun(spec: string): false, string?
---@overload fun(spec: string): true, rocked.raw.Output
function rocked.parse(spec)
	local ok, chunkEnv = rocked.raw(spec)
	if not ok then
		return false, chunkEnv
	end ---@cast chunkEnv rocked.raw.Output

	local build = chunkEnv.build
	if not build then
		return false, "No build section found"
	end

	if not validRockTypes[build.type] then
		return false, "Invalid build type: " .. tostring(build.type)
	end

	return true, chunkEnv
end

return rocked
