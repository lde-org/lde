local sea = require("sea")
local fs = require("fs")
local path = require("path")

local lde = require("lde-core")

local bundlePackage = require("lde-core.package.bundle")

---@param fileName string
---@param exts string[]
---@return string?
local function matchNativeExt(fileName, exts)
	for _, ext in ipairs(exts) do
		if fileName:match("%." .. ext .. "$") then
			return ext
		end
	end
	return nil
end

---@param package lde.Package
---@param targetName? string # release target to cross-compile for (e.g. "windows-x86-64"); nil = native
local function compilePackage(package, targetName)
	-- Resolve the target up front so a typo'd --target fails before any
	-- build/install work. A target matching the host is a native build.
	local target
	if targetName then
		local resolved, terr = sea.getTarget(targetName)
		if not resolved then
			lde.error.raise(terr)
		end ---@cast resolved -nil
		target = resolved
		if sea.isHostTarget(target) then
			target = nil
		end
	end

	-- The whole pipeline — build.lua (via build:cc()/build.target and the CC
	-- env var), rockspec native modules, and sea.compile — reads the current
	-- target so native dependencies are built for the target, not the host.
	lde.global.setTarget(target)

	-- Native shared-library extensions of the target (cross targets build
	-- .dll/.dylib/.so files of their own platform, not the host's).
	local nativeExts
	if target then
		if target.platform == "windows" then
			nativeExts = { "dll" }
		elseif target.platform == "macos" then
			nativeExts = { "so", "dylib" }
		else
			nativeExts = { "so" }
		end
	else
		nativeExts = jit.os == "Windows" and { "dll" }
			or (jit.os == "OSX" and { "so", "dylib" } or { "so" })
	end

	local ok, result = pcall(function()
		package:build()
		package:installDependencies()

		-- Raw bytecode: sea embeds the per-module bytecode as a raw blob (.incbin)
		-- and registers lazy preload loaders over it, so startup only deserializes
		-- the modules a command actually requires.
		local source = bundlePackage(package, { raw = true })

		-- sea.compile throws a raw string when the main module is missing; check
		-- first so a broken project (no src/init.lua, src as a file, ...) fails
		-- cleanly instead of crashing. Packages named "tests" are the one case
		-- where the entry dir is skipped by the test-fixture filter, hence the
		-- name comparison in bundlePackage.
		local mainName = package:getName()
		local hasMain = false
		for _, m in ipairs(source.modules) do
			if m.name == mainName then hasMain = true break end
		end
		if not hasMain then
			lde.error.raise("Cannot compile: no entry module '" .. mainName .. "' in the bundle (is src/init.lua present?)")
		end

		local sharedLibs = {}
		local modulesDir = package:getModulesDir()

		for entry in fs.readdir(modulesDir) do
			local p = path.join(modulesDir, entry.name)
			if entry.name == "tests" and package:getName() ~= "tests" then
				-- lde test exposes the package's tests/ dir as target/tests; test
				-- code must never end up embedded in the executable. A package
				-- *named* "tests" has its own module dir at target/tests — keep it.
				goto continue
			end

			if not fs.isdir(p) then
				local ext = matchNativeExt(entry.name, nativeExts)
				if ext then
					local content = fs.read(p)
					if not content then lde.error.raise("Could not read file: " .. p) end
					local moduleName = entry.name:gsub("%." .. ext .. "$", "")
					table.insert(sharedLibs, { name = moduleName, content = content })
				end
				goto continue
			end

			for _, relativePath in ipairs(fs.scan(p, "**")) do
				local ext = matchNativeExt(relativePath, nativeExts)
				if ext then
					local absPath = path.join(p, relativePath)
					local content = fs.read(absPath)
					if not content then lde.error.raise("Could not read file: " .. absPath) end

					local moduleName = string.gsub(relativePath, path.separator, "."):gsub("%." .. ext .. "$", "")
					moduleName = moduleName ~= "" and (entry.name .. "." .. moduleName) or entry.name
					table.insert(sharedLibs, { name = moduleName, content = content })
				end
			end

			::continue::
		end

		-- sea.compile raises plain strings (unknown target, missing cross
		-- toolchain, compiler failure, dist download); they are surfaced as
		-- clean user-facing errors below, not "lde crashed".
		return sea.compile(package:getName(), source, sharedLibs, lde.global.getCCBin(), targetName)
	end)
	lde.global.setTarget(nil)

	if not ok then
		local msg = tostring(result)
		-- pcall prefixes the error with its chunk position; strip that like the
		-- test framework does so the message stays clean.
		msg = (msg:gsub('^%[string "[^"]*"%]:%d+: ', "", 1))
		msg = (msg:gsub("^@[^:]+:%d+: ", "", 1))
		lde.error.raise(msg)
	end ---@cast result -nil
	return result
end

return compilePackage
