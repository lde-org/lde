--- LuaRocks' `command` backend: run the rockspec's own build/install commands.

const fs = require("fs")
local path = require("path")
const process = require("process")

const lde = require("lde-core")
const env = require("env")

const command = {}

---@param ctx lde.rockspec.BuildContext
---@return boolean?
---@return string?
function command.run(ctx)
	const luajitPath = ctx.luajitPath
	const ldeBin = env.execPath()
	const vars = {
		LUA           = ldeBin,
		LUA_INCDIR    = path.join(luajitPath, "include"),
		LUA_LIBDIR    = path.join(luajitPath, "lib"),
		LIBDIR        = ctx.modulesDir,
		LUADIR        = ctx.modulesDir,
		PREFIX        = ctx.modulesDir,
		CC            = lde.global.getCCCommand(),
		LD            = lde.global.getCCCommand(),
		MAKE          = lde.global.getMakeBin(),
		LIBFLAG       = jit.os == "OSX" and "-shared -undefined dynamic_lookup" or "-shared",
		-- LuaJIT modules are .so on every platform; rockspecs passing
		-- $(LIB_EXTENSION) to their build (luaposix's luke) assume .so.
		LIB_EXTENSION = jit.os == "Windows" and "dll" or "so",
		OBJ_EXTENSION = "o"
	}
	for k, v in pairs(ctx.extVars) do vars[k] = v end
	if ctx.exportFPic then vars.CFLAGS = "-fPIC" end

	const cmdEnv = {}
	for k, v in pairs(vars) do cmdEnv[k] = v end
	const tcEnv = ctx.toolchainEnv()
	if tcEnv then
		for k, v in pairs(tcEnv) do cmdEnv[k] = v end
	end

	---@param cmd string
	local function subst(cmd)
		return (cmd:gsub("%$%(([%w_]+)%)", function(k) return vars[k] or "" end))
	end

	---@param cmd string
	---@return string[]
	local function shellSplit(cmd)
		local args = {}
		local i = 1
		while i <= #cmd do
			while i <= #cmd and cmd:sub(i, i) == " " do i += 1 end
			if i > #cmd then break end
			local token = ""
			while i <= #cmd and cmd:sub(i, i) ~= " " do
				local c = cmd:sub(i, i)
				if c == '"' then
					i += 1
					while i <= #cmd and cmd:sub(i, i) ~= '"' do
						token ..= cmd:sub(i, i)
						i += 1
					end
					if i <= #cmd then i += 1 end
				else
					token ..= c
					i += 1
				end
			end
			args[#args + 1] = token
		end
		return args
	end

	---@param cmdStr string?
	---@return boolean? ok
	---@return string? err
	local function execCmd(cmdStr)
		if not cmdStr or cmdStr == "" then return true end
		local argv = shellSplit(subst(cmdStr))
		local bin = table.remove(argv, 1)
		if not bin then return nil, "empty command" end
		-- Commands that invoke the lde binary run it as plain Lua.
		if bin == ldeBin then
			table.insert(argv, 1, "--lua")
		end
		local code, _, stderr = process.exec(bin, argv, { cwd = ctx.dir, env = cmdEnv })
		if code ~= 0 then
			local msg = (stderr ~= "" and stderr) or ("exited with code " .. code)
			return nil, msg
		end
		return true
	end

	local ok, err = execCmd(ctx.spec.build.build_command)
	if not ok then return nil, "build_command failed: " .. (err or "(no output)") end

	ok, err = execCmd(ctx.spec.build.install_command)
	if not ok then return nil, "install_command failed: " .. (err or "(no output)") end

	fs.write(ctx.stampFile, ctx.buildStamp)
	return true
end

return command
