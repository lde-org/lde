local rocked = {}

---@class rocked.raw.Description
---@field summary string
---@field detailed string
---@field homepage string
---@field license string

---@class rocked.raw.NativeSource
---@field sources string[]
---@field defines string[]?
---@field libraries string[]?
---@field incdirs string[]?
---@field libdirs string[]?

---@alias rocked.raw.BuildSource
--- | string
--- | rocked.raw.NativeSource

---@class rocked.raw.BuildInstall
---@field lua table<string, string>?
---@field bin table<string, string>?
---@field lib table<string, string>?
---@field conf table<string, string>?

---@class rocked.raw.PlatformBuild
---@field modules table<string, rocked.raw.BuildSource>?
---@field install rocked.raw.BuildInstall?

---@class rocked.raw.Build
---@field type "builtin" | "module" | "make" | "cmake" | "none"
---@field modules table<string, rocked.raw.BuildSource>?
---@field install rocked.raw.BuildInstall?
---@field copy_directories string[]?
---@field platforms table<string, rocked.raw.PlatformBuild>?
---@field makefile string?
---@field build_target string?
---@field install_target string?
---@field build_variables table<string, string>?
---@field install_variables table<string, string>?

---@class rocked.raw.Output
---@field version string
---@field package string
---@field description rocked.raw.Description?
---@field source { url: string, branch: string?, tag: string? }
---@field dependencies string[]?
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
	["module"]  = true,
	["make"]    = true,
	["cmake"]   = true,
	["none"]    = true,
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

	build.type = build.type or "builtin"

	if not validRockTypes[build.type] then
		return false, "Invalid build type: " .. tostring(build.type)
	end

	return true, chunkEnv
end

return rocked
