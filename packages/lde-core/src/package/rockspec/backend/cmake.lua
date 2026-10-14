--- LuaRocks' `cmake` backend.

const fs = require("fs")
local path = require("path")
const process = require("process")

const declared = require("lde-core.package.rockspec.declared")

local cmake = {}

---@param ctx lde.rockspec.BuildContext
---@return boolean?
---@return string?
function cmake.run(ctx)
	-- The build dir name is part of the rockspec contract: yuescript declares
	-- install.lib = { "build.luarocks/yue.so" } and build.luarocks/yue.
	local buildDir = path.join(ctx.dir, "build.luarocks")
	local installDir = path.join(ctx.dir, "install.lde")
	if not fs.isdir(buildDir) then fs.mkdirAll(buildDir) end
	if not fs.isdir(installDir) then fs.mkdirAll(installDir) end

	-- $(PREFIX) is the rock's own install dir, so the promote step below finds the
	-- built shared libs.
	const stdVars = ctx.stdVars
	stdVars.PREFIX = ctx.makePath(installDir)

	const configureArgs = {
		"-H.", "-B" .. buildDir,
		"-DLUA_BUILD_TYPE=System",
		"-DWITH_LUA_ENGINE=LuaJIT",
		"-DLUAJIT_INCLUDE_DIR=" .. path.join(ctx.luajitPath, "include"),
		"-DLUAJIT_LIBRARIES=" .. path.join(ctx.luajitPath, "lib", "libluajit.a"),
		"-DCMAKE_INSTALL_PREFIX=" .. installDir
	}
	for k, v in pairs(ctx.spec.build.variables or ctx.spec.build.build_variables or {}) do
		configureArgs[#configureArgs + 1] = "-D" .. k .. "=" .. ctx.subst(v)
	end

	local code, _, stderr = process.exec("cmake", configureArgs, { cwd = ctx.dir })
	if code ~= 0 then return nil, "cmake configure failed: " .. (stderr or "") end

	code, _, stderr = process.exec("cmake", { "--build", buildDir, "--config", "Release" }, { cwd = ctx.dir })
	if code ~= 0 then return nil, "cmake build failed: " .. (stderr or "") end

	code, _, stderr = process.exec("cmake",
		{ "--build", buildDir, "--target", "install", "--config", "Release" }, { cwd = ctx.dir })
	if code ~= 0 then return nil, "cmake install failed: " .. (stderr or "") end

	const soExt = jit.os == "Windows" ? "**.dll" : jit.os == "OSX" ? "**.dylib" : "**.so"
	for _, rel in ipairs(fs.scan(installDir, soExt)) do
		fs.copy(path.join(installDir, rel), path.join(ctx.modulesDir, path.basename(rel)))
	end

	-- A CMakeLists that installs programs drops them into install.lde/bin.
	const installBinDir = path.join(installDir, "bin")
	if fs.isdir(installBinDir) then
		local iter = fs.readdir(installBinDir)
		if iter then
			for entry in iter do
				if entry.type == "file" then
					fs.copy(path.join(installBinDir, entry.name), path.join(ctx.outputDir, entry.name))
				end
			end
		end
	end

	local ok, err = declared.installAll(ctx)
	if not ok then return nil, err end

	fs.write(ctx.stampFile, ctx.buildStamp)
	return true
end

return cmake
