local fs = require("fs")
local path = require("path")

local lde = require("lde-core")

local bundlePackage = require("lde-core.package.bundle")

local nativeExts = jit.os == "Windows" and { "dll" }
	or (jit.os == "OSX" and { "so", "dylib" } or { "so" })

---@param fileName string
---@return string?
local function matchNativeExt(fileName)
	for _, ext in ipairs(nativeExts) do
		if fileName:match("%." .. ext .. "$") then
			return ext
		end
	end
	return nil
end

---@class lde.bloat.File
---@field name string # module name, or native lib name as compile.lua names it
---@field kind "lua" | "native"
---@field bytes number

---@class lde.bloat.Entry
---@field name string # target/ alias the content belongs to (the dependency require name)
---@field bytes number
---@field files lde.bloat.File[]
---@field isRoot boolean # true for the package's own modules (not prunable)

---@class lde.bloat.Report
---@field rootName string
---@field entries lde.bloat.Entry[] # sorted by bytes descending
---@field totalBytes number
---@field luaFiles number
---@field luaBytes number
---@field nativeFiles number
---@field nativeBytes number

--- Build the project and measure what a compiled executable would embed: the
--- per-module LuaJIT bytecode (bundlePackage raw mode) plus every native
--- .so/.dll/.dylib under target/, grouped by the target/ alias they belong to.
--- This is exactly the content compile.lua hands to sea.compile — no C
--- toolchain needed.
---@param package lde.Package
---@return lde.bloat.Report
local function analyze(package)
	package:build()
	package:installDependencies()

	local source = bundlePackage(package, { raw = true })
	local rootName = package:getName()

	---@type table<string, lde.bloat.Entry>
	local entriesByName = {}
	---@type string[]
	local order = {}
	local totalBytes = 0
	local luaFiles = 0
	local luaBytes = 0
	local nativeFiles = 0
	local nativeBytes = 0

	---@param name string
	---@return lde.bloat.Entry
	local function entryFor(name)
		local alias = name:match("^([^.]+)") or name
		local entry = entriesByName[alias]
		if not entry then
			entry = {
				name = alias,
				bytes = 0,
				files = {},
				isRoot = alias == rootName,
			}
			entriesByName[alias] = entry
			order[#order + 1] = alias
		end
		return entry
	end

	---@param name string
	---@param kind "lua" | "native"
	---@param bytes number
	local function addFile(name, kind, bytes)
		local entry = entryFor(name)
		entry.files[#entry.files + 1] = { name = name, kind = kind, bytes = bytes }
		entry.bytes += bytes
		totalBytes += bytes
		if kind == "lua" then
			luaFiles += 1
			luaBytes += bytes
		else
			nativeFiles += 1
			nativeBytes += bytes
		end
	end

	for _, m in ipairs(source.modules) do
		addFile(m.name, "lua", #m.code)
	end

	-- Native libraries embedded by sea.compile, scanned exactly like
	-- compile.lua scans them (tests/ excluded, same naming).
	local modulesDir = package:getModulesDir()
	for entry in fs.readdir(modulesDir) do
		local p = path.join(modulesDir, entry.name)
		if entry.name == "tests" and rootName ~= "tests" then
			goto continue
		end

		if not fs.isdir(p) then
			local ext = matchNativeExt(entry.name)
			if ext then
				local stat = fs.stat(p)
				if stat then
					addFile(entry.name:gsub("%." .. ext .. "$", ""), "native", tonumber(stat.size) or 0)
				end
			end
			goto continue
		end

		for _, relativePath in ipairs(fs.scan(p, "**")) do
			local ext = matchNativeExt(relativePath)
			if ext then
				local absPath = path.join(p, relativePath)
				local stat = fs.stat(absPath)
				if stat then
					local moduleName = string.gsub(relativePath, path.separator, "."):gsub("%." .. ext .. "$", "")
					moduleName = moduleName ~= "" and (entry.name .. "." .. moduleName) or entry.name
					addFile(moduleName, "native", tonumber(stat.size) or 0)
				end
			end
		end

		::continue::
	end

	-- Biggest bloat first, so the prune candidates surface at the top.
	local entries = {}
	for _, alias in ipairs(order) do
		entries[#entries + 1] = entriesByName[alias]
	end
	table.sort(entries, function(a, b) return a.bytes > b.bytes end)
	for _, entry in ipairs(entries) do
		table.sort(entry.files, function(a, b) return a.bytes > b.bytes end)
	end

	return {
		rootName = rootName,
		entries = entries,
		totalBytes = totalBytes,
		luaFiles = luaFiles,
		luaBytes = luaBytes,
		nativeFiles = nativeFiles,
		nativeBytes = nativeBytes,
	}
end

return analyze
