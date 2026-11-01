--- Windows toolchain bootstrap.

const fs = require("fs")
const path = require("path")
const process = require("process")
const ansi = require("ansi")
const env = require("env")
const util = require("util")

const lde = require("lde-core")
const dirs = require("lde-core.global.dirs")
const installLock = require("lde-core.package.install.lock")
const curl = util.lazy(|| -> require("curl-sys"))

local M = {}

const TOOLCHAIN_BASE = "https://github.com/lde-org/toolchain-dist/releases/download/latest"

--- Whether an explicit SEA_CC override resolves. getCCBin uses it directly, so
--- the bundled toolchain is only needed when lde has to supply the compiler.
--- Probed once: the pipeline never changes SEA_CC mid-run, and native builds
--- call ensureMingw once per module.
local seaCcUsable = nil
local function hasSeaCc()
	if seaCcUsable == nil then
		const override = env.var("SEA_CC")
		seaCcUsable = override ~= nil and override ~= ""
			and process.exec(override, { "--version" }) == 0
	end
	return seaCcUsable
end

--- Wraps a download progress callback so a long download keeps the install
--- lock fresh. curl aborts only when the callback returns a truthy value.
---@param handle lde.install.Lock?
---@param progress curl.CurlProgressCallback?
local function heartbeat(handle, progress)
	local lastTouch = 0
	---@type curl.CurlProgressCallback
	local function onProgress(dltotal, dlnow, ultotal, ulnow)
		local now = os.time()
		if now ~= lastTouch then
			installLock.touch(handle)
			lastTouch = now
		end
		if progress then return progress(dltotal, dlnow, ultotal, ulnow) end
		return nil
	end
	return onProgress
end

--- Ensures a toolchain exists at ~/.lde/mingw (Windows only).
--- Downloads a 7z extractor temporarily to extract the .7z archive.
--- Supports x86-64 and aarch64 (ARM64) Windows.
---@param opts? { arch?: string } # override jit.arch for cross-compilation
function M.ensureMingw(opts)
	if jit.os ~= "Windows" then return end

	const arch = opts?.arch ?? jit.arch
	-- Map LuaJIT arch to URL arch names
	local urlArch, sevenZArch
	if arch == "x64" then
		urlArch = "x86-64"
		sevenZArch = "x86_64"
	elseif arch == "arm64" then
		urlArch = "aarch64"
		sevenZArch = "aarch64"
	else
		lde.error.raise("Unsupported architecture for toolchain: " .. arch)
	end

	local TOOLCHAIN_URL = TOOLCHAIN_BASE .. "/toolchain-windows-" .. urlArch .. ".7z"
	local SEVENZ_URL = TOOLCHAIN_BASE .. "/7z-" .. sevenZArch .. ".exe"

	local mingwDir = dirs.getMingwDir()
	local gccPath = path.join(mingwDir, "bin", "gcc.exe")
	if fs.exists(gccPath) then return end

	-- A `gcc` on PATH is not a substitute: getCCBin prefers clang for Windows
	-- builds, and images such as the GitHub Windows runner ship an MSVC-targeted
	-- clang that cannot link the LuaJIT dist's GNU archive. Only the bundled
	-- llvm-mingw is known to match that dist, so install it whenever lde has no
	-- compiler of its own. An explicit SEA_CC is such a compiler: use it and
	-- skip the download, which also keeps CI from fetching a toolchain during
	-- the test run.
	if hasSeaCc() then return end

	-- Parallel native builds (test shards, concurrent installs) can reach
	-- first-run setup together. One process installs while the others wait;
	-- without the lock they all download and one may remove the shared temp
	-- directory while another is still writing into it.
	const handle = installLock.acquire(mingwDir)
	-- The lock holder may have installed the toolchain while we waited.
	if fs.exists(gccPath) then
		installLock.release(handle)
		return
	end

	-- A unique temp dir keeps a retry after a stale-lock steal from writing
	-- over the files another process is reading.
	const token = (path.basename(os.tmpname()):gsub("[^%w]", ""))
	const tmpDir = path.join(dirs.getDir(), "mingw-tmp-" .. (token ~= "" and token or tostring(os.time())))
	local ok, err = pcall(function()
		fs.mkdir(tmpDir)

		local sevenzPath = path.join(tmpDir, "7z.exe")
		local archivePath = path.join(tmpDir, "toolchain.7z")

		const p1 = lde.isVerbose ? ansi.progress("Downloading 7z extractor") : nil
		local ok1, dlErr = curl().download(SEVENZ_URL, sevenzPath,
			{ progress = heartbeat(handle, p1 and ansi.downloadProgress(p1) or nil) })
		if not ok1 then
			if p1 then p1:fail("Downloading 7z extractor") end
			lde.error.raise("Failed to download 7z extractor: " .. (dlErr or ""))
		end
		if p1 then p1:done("Downloaded 7z extractor") end

		const p2 = lde.isVerbose ? ansi.progress("Downloading toolchain") : nil
		local ok2, dlErr2 = curl().download(TOOLCHAIN_URL, archivePath,
			{ progress = heartbeat(handle, p2 and ansi.downloadProgress(p2) or nil) })
		if not ok2 then
			if p2 then p2:fail("Downloading toolchain") end
			lde.error.raise("Failed to download toolchain archive: " .. (dlErr2 or ""))
		end
		if p2 then p2:done("Downloaded toolchain") end

		const p3 = lde.isVerbose ? ansi.progress("Extracting toolchain") : nil
		installLock.touch(handle)
		const extractDir = path.join(tmpDir, "extract")
		fs.mkdir(extractDir)
		local code, _, stderr = process.exec(sevenzPath, { "x", archivePath, "-o" .. extractDir, "-y" })
		if code ~= 0 then
			if p3 then p3:fail() end
			lde.error.raise("Failed to extract toolchain archive: " .. (stderr or ""))
		end

		-- The 7z contains a single top-level folder (toolchain); flatten it.
		const iter = fs.readdir(extractDir)
		local first = iter and iter()
		const sourceDir = first and first.type == "dir" and path.join(extractDir, first.name) or extractDir

		-- A crash mid-install can leave a partial tree (no gcc.exe); replace it
		-- under the lock.
		if fs.exists(mingwDir) then fs.rmdir(mingwDir) end
		local moved, moveErr = fs.move(sourceDir, mingwDir)
		if not moved and not fs.exists(gccPath) then
			lde.error.raise("Failed to install toolchain: " .. (moveErr or "move failed"))
		end

		if p3 then p3:done("Extracted toolchain") end
	end)

	fs.rmdir(tmpDir)
	installLock.release(handle)
	if not ok then error(err, 0) end
end

return M
