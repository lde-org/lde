--- LuaRocks' `builtin`/`module`/`none` backend: copy Lua modules, compile native
--- ones, then install binaries and declared files.

const fs = require("fs")
local path = require("path")
const process = require("process")

const lde = require("lde-core")
const asyncBuild = require("lde-core.util.async-build")
const native = require("lde-core.package.rockspec.native")
const declared = require("lde-core.package.rockspec.declared")

const builtin = {}

---@param ctx lde.rockspec.BuildContext
---@return boolean?, string?, lde.install.DeferredBuild?
function builtin.run(ctx)
	local ok, err = declared.installModules(ctx.modules, ctx.modulesDir, ctx.dir)
	if not ok then return nil, err end

	---@type { child: process.Child?, modname: string, code: number? }[]
	const nativeChildren = {}
	for modname, src in pairs(ctx.nativeModules) do
		-- LuaJIT uses .so on macOS too (its default cpath is ?.so), and rockspec
		-- build systems like luke hardcode .so in their install phase.
		local ext = jit.os == "Windows" and "dll" or "so"
		local destAbs = path.join(ctx.modulesDir, modname:gsub("%.", path.separator) .. "." .. ext)
		const destDir = path.dirname(destAbs)
		if not fs.isdir(destDir) then fs.mkdirAll(destDir) end

		lde.global.ensureMingw()
		const gccArgs = native.gccArgs(src, {
			packageDir = ctx.dir,
			modulesDir = ctx.modulesDir,
			luajitPath = ctx.luajitPath,
			destAbs = destAbs,
			jitOS = jit.os,
			makePath = ctx.makePath,
			targetFlag = lde.global.getTargetFlag(),
			extVars = ctx.extVars,
		})

		-- Async mode (the install build pass): spawn gcc without blocking so
		-- independent rocks compile concurrently; the caller polls and then runs
		-- the finalizer below.
		local ccBin = lde.global.getCCBin()
		const spawnOpts = { env = ctx.toolchainEnv(), stdout = "pipe", stderr = "pipe" }
		if asyncBuild.isActive() then
			local child, serr = process.spawn(ccBin, gccArgs, spawnOpts)
			if not child then
				return nil, "Failed to compile native module '" .. modname .. "': " .. (serr or "spawn failed")
			end
			nativeChildren[#nativeChildren + 1] = { child = child, modname = modname }
		else
			local code, _, stderr = process.exec(ccBin, gccArgs, spawnOpts)
			if code ~= 0 then
				local msg = (stderr ~= "" and stderr) or ("exited with code " .. code)
				return nil, "Failed to compile native module '" .. modname .. "': " .. msg
			end
		end
	end

	-- child:poll() reaps the process on POSIX, so exit codes are captured in
	-- pollNative; wait() here only drains the pipes.
	---@return boolean?
	---@return string?
	local function finishNative()
		for _, nc in ipairs(nativeChildren) do
			local code = nc.code
			local stderr
			if code == nil then
				code, _, stderr = nc.child:wait()
			else
				_, _, stderr = nc.child:wait()
			end
			if code ~= 0 then
				local msg = (stderr ~= "" and stderr) or ("exited with code " .. code)
				return nil, "Failed to compile native module '" .. nc.modname .. "': " .. msg
			end
		end

		local ok2, err2 = declared.installFiles(ctx.binScripts, ctx.outputDir, ctx.dir, false)
		if not ok2 then return nil, err2 end
		declared.installLuaSources(ctx.installLuaFiles, ctx.modulesDir, ctx.dir)
		ok2, err2 = declared.installFiles(ctx.installLibFiles, ctx.modulesDir, ctx.dir, true)
		if not ok2 then return nil, err2 end
		declared.copyDirectories(ctx.spec.build.copy_directories or {}, ctx.modulesDir, ctx.dir)

		fs.write(ctx.stampFile, ctx.buildStamp)
		return true
	end

	if #nativeChildren > 0 then
		---@return boolean?
		local function pollNative()
			for _, nc in ipairs(nativeChildren) do
				if nc.code == nil then
					local code = nc.child:poll()
					if code == nil then return nil end
					nc.code = code
				end
			end
			return true
		end
		return nil, nil, { poll = pollNative, finalize = finishNative }
	end
	return finishNative()
end

return builtin
