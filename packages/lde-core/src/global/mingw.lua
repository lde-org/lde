--- Windows toolchain bootstrap.

const fs = require("fs")
const path = require("path")
const process = require("process")
const ansi = require("ansi")
const util = require("util")

const lde = require("lde-core")
const dirs = require("lde-core.global.dirs")
const curl = util.lazy(|| -> require("curl-sys"))

local M = {}

const TOOLCHAIN_BASE = "https://github.com/lde-org/toolchain-dist/releases/download/latest"

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
	if fs.exists(path.join(mingwDir, "bin", "gcc.exe")) then return end

	-- If gcc is already available on PATH, no need to download
	local code = process.exec("gcc", { "--version" })
	if code == 0 then return end

	const p1 = lde.isVerbose ? ansi.progress("Downloading 7z extractor") : nil

	local tmpDir = path.join(dirs.getDir(), "mingw-tmp")
	fs.mkdir(tmpDir)

	local sevenzPath = path.join(tmpDir, "7z.exe")
	local archivePath = path.join(tmpDir, "toolchain.7z")

	local dlOpts1
	if p1 then
		dlOpts1 = { progress = ansi.downloadProgress(p1) }
	end
	local ok, dlErr = curl().download(SEVENZ_URL, sevenzPath, dlOpts1)
	if not ok then
		fs.rmdir(tmpDir)
		if p1 then p1:fail("Downloading 7z extractor") end
		lde.error.raise("Failed to download 7z extractor: " .. (dlErr or ""))
	end
	if p1 then p1:done("Downloaded 7z extractor") end

	const p2 = lde.isVerbose ? ansi.progress("Downloading toolchain") : nil
	local dlOpts2
	if p2 then
		dlOpts2 = { progress = ansi.downloadProgress(p2) }
	end
	local ok2, dlErr2 = curl().download(TOOLCHAIN_URL, archivePath, dlOpts2)
	if not ok2 then
		fs.rmdir(tmpDir)
		if p2 then p2:fail("Downloading toolchain") end
		lde.error.raise("Failed to download toolchain archive: " .. (dlErr2 or ""))
	end
	if p2 then p2:done("Downloaded toolchain") end

	const p3 = lde.isVerbose ? ansi.progress("Extracting toolchain") : nil
	fs.mkdir(mingwDir)
	local _
	code, _, stderr = process.exec(sevenzPath, { "x", archivePath, "-o" .. mingwDir, "-y" })
	fs.rmdir(tmpDir)
	if code ~= 0 then
		fs.rmdir(mingwDir)
		if p3 then p3:fail() end
		lde.error.raise("Failed to extract toolchain archive: " .. (stderr or ""))
	end

	-- The 7z contains a single top-level folder (toolchain); flatten it
	const entries = fs.readdir(mingwDir)
	local first = entries and entries()
	if first and first.type == "dir" then
		local inner = path.join(mingwDir, first.name)
		local finalDir = mingwDir .. "_swap"
		fs.move(inner, finalDir)
		fs.rmdir(mingwDir)
		fs.move(finalDir, mingwDir)
	end

	if p3 then p3:done("Extracted toolchain") end
end

return M
