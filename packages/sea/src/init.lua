--- sea: bundle Lua source or LuaJIT bytecode into a self-contained native
--- executable. Target/triple resolution lives in sea.target, the C launcher
--- source in sea.emit; this facade re-exports both so `sea.<fn>` stays one API.

const process = require("process")
local path = require("path")
local env = require("env")
const fs = require("fs")
const jit = require("jit")

const seaTarget = require("sea.target")
const emit = require("sea.emit")

const sea = {}
package.loaded[(...)] = sea

sea.targets = seaTarget.targets
sea.getTarget = seaTarget.getTarget
sea.getHostTarget = seaTarget.getHostTarget
sea.isHostTarget = seaTarget.isHostTarget
sea.getTriple = seaTarget.getTriple
sea.getLuajitCacheDir = seaTarget.getLuajitCacheDir
sea.getLuajitPath = seaTarget.getLuajitPath

---@param compiler string
local function isClang(compiler)
	local _, out = process.exec(compiler, { "--version" })
	return out ~= nil and out:find("clang", 1, true) ~= nil
end

--- Extra link flags for a cross compile so a plain clang can link the target
--- without gcc's runtime:
---
---  * `-fuse-ld=lld` — lld links any target (PE/COFF included) without needing
---    target-specific binutils on PATH (clang otherwise falls back to the host
---    linker). Only added when lld is actually available.
---  * `--rtlib=compiler-rt --unwindlib=none` — clang's default runtime is
---    gcc's libgcc (`-lgcc`/`-lgcc_eh`), which fails unless the target's gcc
---    runtime is installed AND detected ("cannot find -lgcc"). Use clang's own
---    runtime instead, when the target's builtins archive exists.
---
---@param compiler string
---@param target sea.Target
local function crossLinkArgs(compiler, target)
	const extra = {}
	local _, lldOut = process.exec("ld.lld", { "--version" })
	if lldOut and lldOut ~= "" then
		extra[#extra + 1] = "-fuse-ld=lld"
	end

	local _, builtins = process.exec(compiler, {
		"--target=" .. target.triple,
		"--rtlib=compiler-rt",
		"-print-libgcc-file-name",
	})
	if builtins and builtins ~= "" then
		local path = builtins:gsub("%s+$", "")
		if fs.exists(path) then
			extra[#extra + 1] = "--rtlib=compiler-rt"
			extra[#extra + 1] = "--unwindlib=none"
		end
	end

	return extra
end

---@param main string # name used as the chunk label
---@param source string|{ name: string, modules: { name: string, code: string }[] } # bundled lua: source string, LuaJIT bytecode string, or a raw bytecode table (bundlePackage { raw = true }) — raw tables are linked as a .incbin blob with lazy preload loaders
---@param sharedLibs? { name: string, content: string }[]
---@param compiler? string # path to compiler binary; defaults to SEA_CC env var, a clang on PATH, then gcc
---@param targetName? string # release target (e.g. "windows-x86-64") to cross-compile for; nil or a host-matching target = native build
function sea.compile(main, source, sharedLibs, compiler, targetName)
	local outPath = path.join(env.tmpdir(), "sea.out")
	sharedLibs = sharedLibs or {}
	local compiler = compiler or env.var("SEA_CC") or "gcc"

	-- Resolve the compile target. A --target matching the host is a native
	-- build: same LuaJIT dist, same flags, no -target flag.
	local target
	if targetName then
		const resolved, terr = seaTarget.getTarget(targetName)
		if not resolved then
			error(terr or ("Unknown compile target '" .. targetName .. "'"))
		end ---@cast resolved -nil
		target = resolved
		if seaTarget.isHostTarget(target) then
			target = nil
		end
	end

	-- Cross compilation goes through clang's -target; a bare gcc can't do it.
	-- The normal pipeline resolves a clang via lde.global.getCCBin(); this is a
	-- backstop for direct sea.compile callers.
	if target and not isClang(compiler) then
		error("Cross-compiling to '" .. target.name .. "' requires clang, but the resolved compiler is '"
			.. compiler .. "'. Install clang, or set SEA_CC to a clang with a sysroot for '" .. target.triple .. "'.")
	end

	-- The platform this binary runs on: the target's when cross-compiling,
	-- the host's otherwise. Drives lib naming, the ffi shim, and link flags.
	local platform = target?.platform
		or (jit.os == "Windows" and "windows" or jit.os == "OSX" and "macos" or jit.os == "BSD" and "freebsd" or "linux")
	local code = emit.buildSource(main, source, sharedLibs, platform)

	local ljPath = seaTarget.getLuajitPath(compiler, target)
	local includePath = path.join(ljPath, "include")
	local libPath = path.join(ljPath, "lib")

	local args = {
		"-I" .. includePath,
		"-xc", "-",
		"-o", outPath,
		"-xnone",
	}

	-- Cross compilation: clang targets a foreign platform via -target. The
	-- target's LuaJIT headers/libs come from the downloaded dist; the compiler
	-- (resolved by lde.global.getCCBin) supplies the rest of the toolchain.
	if target then
		args[#args + 1] = "--target=" .. target.triple
		-- Prefer lld and clang's own runtime so the link doesn't need the
		-- target's gcc (libgcc) to be installed and detected.
		for _, flag in ipairs(crossLinkArgs(compiler, target)) do
			args[#args + 1] = flag
		end
	end

	if platform == "windows" then
		-- Wrap libluajit.a in --whole-archive: link in ALL of its object
		-- files, not just the ones lde itself references. Symbols only ever
		-- called by C modules at runtime (e.g. luaJIT_profile_*) must be
		-- physically present in the exe for --export-all-symbols below to
		-- be able to export them.
		args[#args + 1] = "-Wl,--whole-archive"
		args[#args + 1] = path.join(libPath, "libluajit.a")
		args[#args + 1] = "-Wl,--no-whole-archive"
	else
		args[#args + 1] = path.join(libPath, "libluajit.a")
	end

	if platform == "linux" then
		args[#args + 1] = "-lm"
		args[#args + 1] = "-ldl"
		args[#args + 1] = "-Wl,--export-dynamic" -- expose lua symbols for lua dependencies
	elseif platform == "freebsd" then
		args[#args + 1] = "-lm" -- freebsd's dlopen is in libc
		args[#args + 1] = "-Wl,--export-dynamic" -- expose lua symbols for lua dependencies
	elseif platform == "macos" then
		args[#args + 1] = "-Wl,-export_dynamic" -- expose lua symbols for lua dependencies
	elseif platform == "windows" then
		-- Export lua symbols so C modules can resolve them from the process
		-- image (GetModuleHandle(NULL) + GetProcAddress), matching the
		-- --export-dynamic behavior on Linux/macOS.
		args[#args + 1] = "-Wl,--export-all-symbols"
	end
	local execEnv
	if jit.os == "Windows" and compiler ~= "gcc" then
		-- compiler is a full path into mingw/bin; ensure subtools (as.exe etc) are found
		execEnv = { PATH = path.dirname(compiler) .. ";" .. (env.var("PATH") or "") }
	end
	local code, stdout, stderr = process.exec(compiler, args, { stdin = code, env = execEnv })
	if code ~= 0 or string.find(stderr or "", "is not recognized as an internal", 1, true) then
		local err = (stderr and stderr ~= "" and stderr) or (stdout and stdout ~= "" and stdout) or ""
		-- A clang that still links libgcc (no compiler-rt builtins for the
		-- target) fails with "cannot find -lgcc" when the target's gcc runtime
		-- isn't installed or wasn't detected — point at the missing piece.
		if target
			and (err:find("cannot find %-lgcc", 1)
				or err:find("unable to find library %-lgcc", 1)) then
			if target.platform == "freebsd" then
				err = err
					.. "\n[sea] cross-compiling to FreeBSD needs a FreeBSD sysroot (the target's base system, "
					.. "e.g. installed from base.txz): set SEA_CC to a clang wrapper that passes "
					.. "--sysroot=<sysroot> for '" .. target.triple .. "'."
			else
				err = err
					.. "\n[sea] the target's C runtime is missing: clang is linking libgcc (-lgcc), but no libgcc for '"
					.. target.triple .. "' was found. Install the target's gcc runtime (e.g. on Fedora: dnf install mingw64-gcc),"
					.. " or use a clang with compiler-rt builtins for the target (e.g. llvm-mingw)."
			end
		end
		error("Compilation failed: " .. err)
	end

	return outPath
end

return sea
