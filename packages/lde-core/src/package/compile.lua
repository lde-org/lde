const sea = require("sea")
const fs = require("fs")

const features = require("lde-core.package.features")

const nativeext = require("lde-core.package.nativeext")

const lde = require("lde-core")

const timings = require("lde-core.util.timings")

const bundlePackage = require("lde-core.package.bundle")

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

	-- Cross-compiling selects the target's suffixes; a native build selects the host's.
	const nativeExts = nativeext.extsFor(target ? target.platform : nativeext.hostPlatform())

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

		-- Same feature globs as the Lua half of the bundle, so a feature can drop a native backend as well as the Lua driving it.
		for _, file in ipairs(nativeext.scan(package:getModulesDir(), {
			exts = nativeExts,
			rootName = package:getName(),
			excludesFor = features.resolverFor(package),
		})) do
			local content = fs.read(file.path)
			if not content then lde.error.raise("Could not read file: " .. file.path) end
			table.insert(sharedLibs, { name = file.name, content = content })
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
