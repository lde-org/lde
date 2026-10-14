--- LuaRocks' `make` backend.

const fs = require("fs")
local path = require("path")
const process = require("process")

const lde = require("lde-core")
const declared = require("lde-core.package.rockspec.declared")

local make = {}

---@param ctx lde.rockspec.BuildContext
---@return boolean?
---@return string?
function make.run(ctx)
	lde.global.ensureMingw()
	local makeBin = lde.global.getMakeBin()
	if not process.exec(makeBin, { "--version" }) then
		return nil,
			"Package '" .. (ctx.spec.package or "?") .. "' requires 'make' to build, but it was not found." ..
			" Install make (e.g. build-essential on Debian/Ubuntu, Xcode Command Line Tools on macOS)."
	end

	-- LuaRocks puts only the variables a rockspec explicitly asks for on make's
	-- command line, and exports the standard ones through the environment
	-- instead: make imports environment variables as make variables, but any
	-- assignment in the Makefile still wins. Forcing them on the command line
	-- suppressed Makefile assignments, including `+=` (lgi on macOS).
	---@type table<string, string>
	const makeEnv = ctx.toolchainEnv() or {}
	for k, v in pairs(ctx.stdVars) do makeEnv[k] = v end

	---@param extraVars table<string, string>?
	---@return string[]
	local function buildVarList(extraVars)
		local args = {}
		for k, v in pairs(extraVars or {}) do
			args[#args + 1] = k .. "=" .. ctx.subst(v)
		end
		return args
	end

	-- build.makefile selects a non-default makefile (cqueues: GNUmakefile).
	local makefileArgs = ctx.spec.build.makefile and { "-f", ctx.spec.build.makefile } or {}
	const buildTarget = ctx.spec.build.build_target or ""
	const installTarget = ctx.spec.build.install_target or "install"

	local buildArgs = buildVarList(ctx.spec.build.variables)
	for _, a in ipairs(makefileArgs) do buildArgs[#buildArgs + 1] = a end
	if buildTarget ~= "" then buildArgs[#buildArgs + 1] = buildTarget end

	local code, _, stderr = process.exec(makeBin, buildArgs, { cwd = ctx.dir, env = makeEnv })
	if code ~= 0 then
		local msg = (stderr ~= "" and stderr) or ("exited with code " .. code)
		return nil, "make failed: " .. msg
	end

	-- build.variables apply to both passes; install_variables layer on top
	-- (lgi's install target reads LUA_LIBDIR, defined only in build.variables).
	const installVars = {}
	for k, v in pairs(ctx.spec.build.variables or {}) do installVars[k] = v end
	for k, v in pairs(ctx.spec.build.install_variables or {}) do installVars[k] = v end
	local installArgs = buildVarList(installVars)
	for _, a in ipairs(makefileArgs) do installArgs[#installArgs + 1] = a end
	installArgs[#installArgs + 1] = installTarget

	code, _, stderr = process.exec(makeBin, installArgs, { cwd = ctx.dir, env = makeEnv })
	if code ~= 0 then
		local msg = (stderr ~= "" and stderr) or ("exited with code " .. code)
		return nil, "make install failed: " .. msg
	end

	-- Makefile installs land in the module dir's bin/ (LuaRocks points INST_LIBDIR
	-- at it); the package's target dir is where `lde run`/`lde x` look.
	const binDir = path.join(ctx.modulesDir, "bin")
	if fs.isdir(binDir) then
		local iter = fs.readdir(binDir)
		if iter then
			for entry in iter do
				if entry.type == "file" then
					fs.copy(path.join(binDir, entry.name), path.join(ctx.outputDir, entry.name))
				end
			end
		end
	end

	local ok, err = declared.installAll(ctx)
	if not ok then return nil, err end

	fs.write(ctx.stampFile, ctx.buildStamp)
	return true
end

return make
