--- Compile-target resolution: the release target table, host triple probing
--- and the per-target LuaJIT dist cache. The `sea` facade re-exports these.

const Target = {}

const process = require("process")
local path = require("path")
local env = require("env")
const fs = require("fs")
const jit = require("jit")
const ansi = require("ansi")

const util = require("util")

const curl = util.lazy(|| -> require("curl-sys"))
const Archive = util.lazy(|| -> require("archive"))

local ljDistRepo = "lde-org/luajit"
local ljDistTag = "latest"

local function getPlatformArch()
	local platform = jit.os == "Linux" and "linux"
		or jit.os == "Windows" and "windows"
		or jit.os == "OSX" and "macos"
		or jit.os == "BSD" and "freebsd"
		or error("Unsupported platform: " .. jit.os)

	local arch = jit.arch == "x64" and "x86-64"
		or jit.arch == "arm64" and "aarch64"
		or error("Unsupported architecture: " .. jit.arch)

	return platform, arch
end

--- Parse arch and libc from a compiler's -dumpmachine output.
--- Returns nil for both if the platform doesn't use a libc triplet component
--- (OSX, FreeBSD).
--- On Linux, derives arch from the triplet so cross-compilers (e.g. Android NDK) work correctly.
---@param compiler string
---@return string|nil arch  -- e.g. "x86-64" or "aarch64"
---@return "musl" | "gnu" | "android" | nil libc
local function getTargetFromCompiler(compiler)
	if jit.os == "OSX" or jit.os == "BSD" then return nil, nil end
	if jit.os == "Windows" then return nil, "gnu" end

	---@type string?
	local arch

	-- Use the compiler's -dumpmachine to get the target triplet.
	local code, out = process.exec(compiler, { "-dumpmachine" })
	if code == 0 and out and out ~= "" then
		out = out:match("^%s*(.-)%s*$")

		if out:find("^x86_64") or out:find("^x86%-64") then
			arch = "x86-64"
		elseif out:find("^aarch64") then
			arch = "aarch64"
		end

		local libc
		if out:find("android", 1, true) then
			libc = "android"
		elseif out:find("musl", 1, true) then
			libc = "musl"
		elseif out:find("gnu", 1, true) then
			libc = "gnu"
		end

		if arch and libc then
			return arch, libc
		end
	end

	const lddPatterns = { ["musl"] = "musl", ["gnu"] = "GNU libc" }

	local _, lddout = process.exec("ldd", { "--version" })
	for libc, pattern in pairs(lddPatterns) do
		if string.find(lddout or "", pattern, 1, true) then return arch, libc end
	end

	io.stderr:write("[sea] warning: could not detect target from compiler '" .. compiler .. "', defaulting to gnu\n")

	return arch, "gnu"
end

---@class sea.Target
---@field name string # release target name, e.g. "linux-x86-64"
---@field platform string # "linux" | "windows" | "macos" | "freebsd" — also the LuaJIT dist platform
---@field arch string # "x86-64" | "aarch64"
---@field libc? string # "gnu" | "musl" | "android"; nil on macos/freebsd (no libc component in the dist name)
---@field triple string # clang -target used for cross compilation

-- The targets lde ships in GitHub releases (see .github/workflows/release.yml).
-- Cross-compiling to one of these uses clang's --target with the target's
-- LuaJIT dist; the compiler (and its sysroot, when the target needs one) is
-- resolved automatically — the bundled toolchain covers Windows targets.
Target.targets = {
	["linux-x86-64"]    = { name = "linux-x86-64",    platform = "linux",   arch = "x86-64",  libc = "gnu",     triple = "x86_64-linux-gnu" },
	["linux-aarch64"]   = { name = "linux-aarch64",   platform = "linux",   arch = "aarch64", libc = "gnu",     triple = "aarch64-linux-gnu" },
	["windows-x86-64"]  = { name = "windows-x86-64",  platform = "windows", arch = "x86-64",  libc = "gnu",     triple = "x86_64-w64-windows-gnu" },
	["windows-aarch64"] = { name = "windows-aarch64", platform = "windows", arch = "aarch64", libc = "gnu",     triple = "aarch64-w64-windows-gnu" },
	["macos-x86-64"]    = { name = "macos-x86-64",    platform = "macos",   arch = "x86-64",                  triple = "x86_64-apple-darwin" },
	["macos-aarch64"]   = { name = "macos-aarch64",   platform = "macos",   arch = "aarch64",                 triple = "aarch64-apple-darwin" },
	["freebsd-x86-64"]  = { name = "freebsd-x86-64",  platform = "freebsd", arch = "x86-64",                  triple = "x86_64-unknown-freebsd" },
	["freebsd-aarch64"] = { name = "freebsd-aarch64", platform = "freebsd", arch = "aarch64",                 triple = "aarch64-unknown-freebsd" },
	["android-aarch64"] = { name = "android-aarch64", platform = "linux",   arch = "aarch64", libc = "android", triple = "aarch64-linux-android" },
}

--- Look up a release target by name.
---@param name string
---@return sea.Target? target
---@return string? err # lists the valid names when the target is unknown
function Target.getTarget(name)
	local target = Target.targets[name]
	if not target then
		local names = {}
		for n in pairs(Target.targets) do names[#names + 1] = n end
		table.sort(names)
		return nil, "Unknown compile target '" .. name .. "' (expected one of: " .. table.concat(names, ", ") .. ")"
	end
	return target
end

--- The host platform/arch/libc, shaped like a target (no name/triple).
---@param compiler? string
---@return { platform: string, arch: string, libc: string|nil }
function Target.getHostTarget(compiler)
	local platform, hostArch = getPlatformArch()
	local probeArch, libc = getTargetFromCompiler(compiler or env.var("SEA_CC") or "gcc")
	return { platform = platform, arch = probeArch or hostArch, libc = libc }
end

--- Whether a target matches the host (a native build, not a cross compile).
---@param target sea.Target
function Target.isHostTarget(target)
	const host = Target.getHostTarget()
	return target.platform == host.platform
		and target.arch == host.arch
		and (target.libc or "") == (host.libc or "")
end

--- The clang triple for a target, or the host triple when native (derived
--- from the compiler's -dumpmachine, falling back to jit-derived defaults).
---@param target? sea.Target
---@param compiler? string
---@return string
function Target.getTriple(target, compiler)
	if target then return target.triple end

	local compiler = compiler or env.var("SEA_CC") or "gcc"
	local _, out = process.exec(compiler, { "-dumpmachine" })
	if out and out ~= "" then
		local triple = out:match("^%s*(.-)%s*$")
		if triple and triple ~= "" then return triple end
	end

	local platform, arch = getPlatformArch()
	const tripleArch = arch == "aarch64" and "aarch64" or "x86_64"
	return (platform == "windows" and (tripleArch .. "-w64-windows-gnu"))
		or (platform == "macos" and (tripleArch .. "-apple-darwin"))
		or (platform == "freebsd" and (tripleArch .. "-unknown-freebsd"))
		or (tripleArch .. "-linux-gnu")
end

local function userLdeDir()
	const ldeHome = os.getenv("LDE_HOME")
	if ldeHome and ldeHome ~= "" then return ldeHome end
	return path.join(os.getenv("HOME") or os.getenv("USERPROFILE") or "", ".lde")
end

local function getLuajitCacheDir()
	return path.join(userLdeDir(), "luajit")
end

Target.getLuajitCacheDir = getLuajitCacheDir

---@param compiler? string
---@param target? sea.Target # cross-compile target; nil = native host build
local function getLuajitPath(compiler, target)
	local compiler = compiler or env.var("SEA_CC") or "gcc"

	local cacheDir = getLuajitCacheDir()
	local platform, hostArch = getPlatformArch()
	local arch, libc
	if target then
		platform = target.platform
		arch = target.arch
		libc = target.libc
	else
		const compilerArch, probeLibc = getTargetFromCompiler(compiler)
		arch = compilerArch or hostArch
		libc = probeLibc
	end

	const distName = table.concat({ "libluajit", platform, arch, libc }, "-")
	local targetDir = path.join(cacheDir, distName)

	if fs.exists(path.join(targetDir, "include", "lua.h")) then
		return targetDir
	end

	fs.mkdirAll(cacheDir)

	const tarballName = distName .. ".tar.gz"
	local downloadUrl = string.format(
		"https://github.com/%s/releases/download/%s/%s",
		ljDistRepo,
		ljDistTag,
		tarballName
	)
	local tarballPath = path.join(cacheDir, tarballName)

	local ljLabel = "luajit for " .. (target?.name ?? (platform .. "-" .. arch))

	const bar = ansi.progress("Downloading " .. ljLabel, { indent = false })
	local ok, dlErr = curl().download(downloadUrl, tarballPath, {
		progress = function(dltotal, dlnow)
			local ratio = dltotal > 0 ? (dlnow / dltotal) : nil
			const info = dltotal > 0
				and (ansi.formatBytes(dlnow) .. " / " .. ansi.formatBytes(dltotal))
				or ansi.formatBytes(dlnow)
			bar:update(ratio, info)
		end
	})
	if not ok then
		bar:fail("Downloading " .. ljLabel)
		error("Failed to download LuaJIT from " .. downloadUrl .. ": " .. (dlErr or ""))
	end
	bar:done("Downloaded " .. ljLabel)

	local ok, err = Archive().new(tarballPath):extract(cacheDir)
	if not ok then
		-- The cache outlives this process now, so a half-extracted dist must not
		-- stay behind: the next build trusts include/lua.h as the only check and
		-- would link against a truncated libluajit.a.
		fs.rmdir(targetDir)
		error("Failed to extract LuaJIT from " .. tarballPath .. ": " .. (err or ""))
	end

	fs.delete(tarballPath)

	return targetDir
end

Target.getLuajitPath = getLuajitPath

return Target
