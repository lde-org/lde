const fs = require("fs")

const features = require("lde-core.package.features")

const nativeext = require("lde-core.package.nativeext")

const bundlePackage = require("lde-core.package.bundle")

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

--- Measures what a compiled executable would embed — exactly the content compile.lua hands to sea.compile, so no C toolchain is needed.
---@param package lde.Package
---@return lde.bloat.Report
local function analyze(package)
	package:build()
	package:installDependencies()

	const source = bundlePackage(package, { raw = true })
	local rootName = package:getName()

	---@type table<string, lde.bloat.Entry>
	const entriesByName = {}
	---@type string[]
	const order = {}
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

	-- Scanned exactly like compile.lua (tests/ excluded, same naming and feature-flag exclusions) so the report answers "what the executable will contain".
	for _, file in ipairs(nativeext.scan(package:getModulesDir(), {
		exts = nativeext.extsFor(nativeext.hostPlatform()),
		rootName = rootName,
		excludesFor = features.resolverFor(package),
	})) do
		const stat = fs.stat(file.path)
		if stat then
			addFile(file.name, "native", tonumber(stat.size) or 0)
		end
	end

	local entries = {}
	for _, alias in ipairs(order) do
		entries[#entries + 1] = entriesByName[alias]
	end
	table.sort(entries, |a, b| -> a.bytes > b.bytes)
	for _, entry in ipairs(entries) do
		table.sort(entry.files, |a, b| -> a.bytes > b.bytes)
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
