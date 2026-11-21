const sea = require("sea")
const fs = require("fs")

const features = require("lde-core.package.features")

const nativeext = require("lde-core.package.nativeext")

const lde = require("lde-core")

const timings = require("lde-core.util.timings")

const bundlePackage = require("lde-core.package.bundle")
const exportScanner = require("lde-core.package.exports")

---@param package lde.Package
---@param targetName? string # release target to cross-compile for (e.g. "windows-x86-64"); nil = native
---@param opts? { shared: boolean? } # shared: link a shared library exporting the package's `---@export` functions
local function compilePackage(package, targetName, opts)
	const isShared = opts ~= nil and opts.shared == true
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
		---@type sea.Export[]
		const exports = {}
		---@type table<string, string>
		const exportOrigin = {}
		---@type (fun(content: string, chunkName: string): string)?
		local transform
		if isShared then
			---@param content string
			---@param chunkName string
			transform = function(content, chunkName)
				-- The Teal build keeps each .tl next to the .lua it generated; its annotations live only there.
				const tealPath = chunkName:gsub("%.lua$", ".tl")
				const tealSource = tealPath ~= chunkName and fs.read(tealPath)
				if tealSource then
					local transplanted, terr = exportScanner.transplant(content, tealSource, tealPath)
					if not transplanted then lde.error.raise(terr) end ---@cast transplanted -nil
					content, chunkName = transplanted, tealPath
				end

				local rewritten, found, err = exportScanner.process(content, chunkName)
				if not rewritten or not found then lde.error.raise(err) end ---@cast rewritten -nil
				---@cast found -nil
				for _, export in ipairs(found) do
					if exportOrigin[export.name] then
						lde.error.raise("export '" .. export.name .. "' is declared twice: in "
							.. exportOrigin[export.name] .. " and " .. chunkName)
					end
					exportOrigin[export.name] = chunkName
					exports[#exports + 1] = export
				end
				return rewritten
			end
		end
		local source = bundlePackage(package, { raw = true, transform = transform })
		if bundleHandle then timings.finish(bundleHandle) end

		if isShared and #exports == 0 then
			lde.error.raise('Cannot compile a shared library: no `---@export "C"` annotations found in ' .. package:getName())
		end

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
		const executable = isShared
			? sea.compileShared(mainName, source, sharedLibs, exports, lde.global.getCCBin(), targetName)
			: sea.compile(mainName, source, sharedLibs, lde.global.getCCBin(), targetName)
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
