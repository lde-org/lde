const sea = require("sea")
const fs = require("fs")
const path = require("path")

const features = require("lde-core.package.features")

const lde = require("lde-core")

const timings = require("lde-core.util.timings")

const bundlePackage = require("lde-core.package.bundle")

---@param fileName string
---@param exts string[]
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
	-- Resolved up front so a typo'd --target fails before any build/install work; a target matching the host is a native build.
	local target
	if targetName then
		const resolved, terr = sea.getTarget(targetName)
		if not resolved then
			lde.error.raise(terr)
		end ---@cast resolved -nil
		target = resolved
		if sea.isHostTarget(target) then
			target = nil
		end
	end

	-- The whole pipeline (build.lua, rockspec native modules, sea.compile) reads the current target so native dependencies are built for the target, not the host.
	lde.global.setTarget(target)

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

	const ok, result = pcall(function()
		const rootBuild = timings.active()
			? timings.start("build " .. package:getName(), "build") : nil
		package:build()
		if rootBuild then timings.finish(rootBuild) end
		package:installDependencies()

		-- Raw bytecode: sea embeds it as a blob and registers lazy preload loaders, so startup only deserializes the modules a command actually requires.
		const bundleHandle = timings.active()
			? timings.start("bundle " .. package:getName(), "bundle") : nil
		local source = bundlePackage(package, { raw = true })
		if bundleHandle then timings.finish(bundleHandle) end

		-- sea.compile throws a raw string when the main module is missing; check first so a broken project fails cleanly. Packages named "tests" skip the entry dir via the test-fixture filter, hence the name comparison in bundlePackage.
		local mainName = source.name
		local hasMain = false
		for _, m in ipairs(source.modules) do
			if m.name == mainName then hasMain = true break end
		end
		if not hasMain then
			const bin = package:readConfig().bin
			lde.error.raise("Cannot compile: no entry module '" .. mainName .. "' in the bundle (is "
				.. (bin and ("src/" .. bin) or "src/init.lua") .. " present?)")
		end

		local sharedLibs = {}
		local modulesDir = package:getModulesDir()

		-- Same feature globs as the Lua half of the bundle, so a feature can drop a native backend as well as the Lua driving it.
		const excludesFor = features.resolverFor(package)

		for entry in fs.readdir(modulesDir) do
			local p = path.join(modulesDir, entry.name)
			if entry.name == "tests" and package:getName() ~= "tests" then
				-- Test code must never end up embedded; a package *named* "tests" has its own module dir at target/tests, so keep it.
				goto continue
			end

			const excludes = excludesFor(entry.name)

			if not fs.isdir(p) then
				local ext = matchNativeExt(entry.name, nativeExts)
				if ext and not features.isExcluded(entry.name, excludes) then
					local content = fs.read(p)
					if not content then lde.error.raise("Could not read file: " .. p) end
					local moduleName = entry.name:gsub("%." .. ext .. "$", "")
					table.insert(sharedLibs, { name = moduleName, content = content })
				end
				goto continue
			end

			for _, relativePath in ipairs(fs.scan(p, "**")) do
				local ext = matchNativeExt(relativePath, nativeExts)
				if ext and not features.isExcluded(relativePath, excludes) then
					const absPath = path.join(p, relativePath)
					local content = fs.read(absPath)
					if not content then lde.error.raise("Could not read file: " .. absPath) end

					local moduleName = string.gsub(relativePath, path.separator, "."):gsub("%." .. ext .. "$", "")
					moduleName = moduleName ~= "" and (entry.name .. "." .. moduleName) or entry.name
					table.insert(sharedLibs, { name = moduleName, content = content })
				end
			end

			::continue::
		end

		-- sea.compile raises plain strings, surfaced as clean user-facing errors below, not "lde crashed".
		const seaHandle = timings.active() ? timings.start("sea compile", "compile") : nil
		const executable = sea.compile(mainName, source, sharedLibs, lde.global.getCCBin(), targetName)
		if seaHandle then timings.finish(seaHandle) end
		return executable
	end)
	lde.global.setTarget(nil)

	if not ok then
		local msg = tostring(result)
		-- pcall prefixes the error with its chunk position; strip it like the test framework does.
		msg = (msg:gsub('^%[string "[^"]*"%]:%d+: ', "", 1))
		msg = (msg:gsub("^@[^:]+:%d+: ", "", 1))
		lde.error.raise(msg)
	end ---@cast result -nil
	return result
end

return compilePackage
