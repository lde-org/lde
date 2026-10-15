--- Compile target, C compiler, make and shell resolution.

local fs = require("fs")
local path = require("path")
const process = require("process")
const env = require("env")
const util = require("util")

const lde = require("lde-core")
const sea = util.lazy(|| -> require("sea"))
const dirs = require("lde-core.global.dirs")

local M = {}

--- Whether `clang` resolves on PATH. Probed once per process (env vars and
--- PATH don't change mid-run for the compile pipeline).
local clangProbe = nil
local function clangOnPath()
	if clangProbe == nil then
		local code = process.exec("clang", { "--version" })
		clangProbe = code == 0
	end
	return clangProbe
end

--- The compile target for the current build, set around `lde compile
--- --target=X` (nil = native). The whole build/install pipeline (build.lua,
--- rockspec native modules, sea) reads this so native dependencies are built
--- for the target, not the host.
---@type sea.Target?
local currentTarget = nil

---@param target sea.Target? # nil = native build
function M.setTarget(target)
	currentTarget = target
end

function M.getTarget()
	return currentTarget
end

--- Stable key for the current target, mixed into build/install stamps so a
--- target switch forces native dependencies to rebuild.
function M.getTargetKey()
	local target = currentTarget
	return target?.name ?? ""
end

--- The clang -target flag for the current cross target, nil when native.
function M.getTargetFlag()
	local target = currentTarget
	if not target then return nil end
	return "--target=" .. target.triple
end

--- The clang triple for the current build: the target triple when
--- cross-compiling, the host triple otherwise (e.g. for build:target()).
---@return string
function M.getTargetTriple()
	local target = currentTarget
	if target then return target.triple end
	return sea().getTriple(nil, M.getCCBin())
end

--- The compiler invocation for the current target: the compiler binary plus
--- the clang -target flag when cross-compiling. Suitable for CC=/LD= env
--- vars passed to make/cmake from build scripts and rockspec builds.
function M.getCCCommand()
	const cc = M.getCCBin()
	const flag = M.getTargetFlag()
	return flag ? (cc .. " " .. flag) : cc
end

--- Resolve the C compiler used for builds and sea compilation. Prefers clang
--- (SEA_CC override, the bundled Windows toolchain, then PATH) so cross
--- compilation works through clang's --target; falls back to gcc when no clang
--- is available (native builds only — cross requires clang).
---@return string
function M.getCCBin()
	local override = env.var("SEA_CC")
	if override and override ~= "" then
		return override
	end

	if currentTarget then
		-- Cross compile: clang only (it carries -target). Prefer the bundled
		-- clang toolchain on Windows — it is llvm-mingw and cross-compiles
		-- every Windows target out of the box. Otherwise a clang on PATH (the
		-- target's sysroot, if needed, must then be reachable by clang).
		local clang
		if jit.os == "Windows" then
			local mingwClang = path.join(dirs.getMingwDir(), "bin", "clang.exe")
			if fs.exists(mingwClang) then
				clang = mingwClang
			end
		end
		if not clang and clangOnPath() then
			clang = "clang"
		end
		if not clang then
			lde.error.raise("Cross-compiling to '" .. currentTarget.name
				.. "' requires clang, but none was found. Install clang, or set SEA_CC to a clang with a sysroot for '"
				.. currentTarget.triple .. "'.")
		end
		return clang
	end

	-- The bundled Windows toolchain is llvm-mingw (Clang/LLD + sysroot): its
	-- clang is guaranteed compatible with the LuaJIT Windows dist, while a
	-- PATH clang may be MSVC-targeted.
	if jit.os == "Windows" then
		local mingwClang = path.join(dirs.getMingwDir(), "bin", "clang.exe")
		if fs.exists(mingwClang) then
			return mingwClang
		end
	end

	if clangOnPath() then
		return "clang"
	end

	if jit.os == "Windows" then
		const mingwGcc = path.join(dirs.getMingwDir(), "bin", "gcc.exe")
		if fs.exists(mingwGcc) then
			return mingwGcc
		end
	end

	return "gcc"
end

--- Returns the make binary used for builds.
--- On Windows, prefers the bundled mingw toolchain's mingw32-make (the
--- conventional name there) and falls back to the bare name so a make on
--- PATH is used when no toolchain is installed.
function M.getMakeBin()
	if jit.os == "Windows" then
		const mingwMake = path.join(dirs.getMingwDir(), "bin", "mingw32-make.exe")
		if fs.exists(mingwMake) then
			return mingwMake
		end
		const makeExe = path.join(dirs.getMingwDir(), "bin", "make.exe")
		if fs.exists(makeExe) then
			return makeExe
		end
		return "mingw32-make"
	end

	return "make"
end

--- Returns the shell used to run lde.json scripts and shell commands. On
--- Windows, prefers the bundled toolchain's BusyBox sh so scripts get POSIX
--- semantics (positional args, quoting) on every platform; falls back to
--- cmd.exe when no toolchain is installed.
---@return string flag
---@return boolean isCmd # true when the shell is cmd.exe (double-quote escaping)
function M.getScriptShell()
	if jit.os == "Windows" then
		local shExe = path.join(dirs.getMingwDir(), "bin", "sh.exe")
		if fs.exists(shExe) then
			return shExe, "-c", false
		end
		return "cmd", "/c", true
	end
	return "sh", "-c", false
end

--- Absolute path of the POSIX shell, for `#!` lines: a shebang is resolved by the
--- kernel without PATH, and not every system keeps a shell at /bin/sh — Termux on
--- Android keeps it under $PREFIX/bin, so a hardcoded /bin/sh silently fails to
--- exec there. Windows gets the bundled BusyBox sh when the toolchain is
--- installed (callers on Windows branch on getScriptShell instead).
function M.getShellPath()
	if jit.os == "Windows" then
		const shExe = path.join(dirs.getMingwDir(), "bin", "sh.exe")
		if fs.exists(shExe) then return shExe end
		return os.getenv("COMSPEC") or "cmd.exe"
	end
	const pathVar = os.getenv("PATH") or ""
	for dir in pathVar:gmatch("[^:]+") do
		---@cast dir string
		const candidate = path.join(dir, "sh")
		const stat = fs.stat(candidate)
		if stat and (stat.mode ?? 0) & 0x49 ~= 0 then -- any exec bit
			return candidate
		end
	end
	return "/bin/sh"
end

return M
