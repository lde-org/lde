--- Bin shims written into the tools dir.

const fs = require("fs")
const path = require("path")
const process = require("process")
const env = require("env")
const ansi = require("ansi")

const lde = require("lde-core")
const dirs = require("lde-core.global.dirs")

local M = {}

--- Writes the platform-appropriate wrapper script into ~/.lde/tools/.
--- The `--` separator stops lde's own arg parser from swallowing tool args that
--- start with a dash (e.g. `tl --help`), so they are passed through to the tool.
--- The wrapper execs the exact binary that installed it (env.execPath) rather
--- than a bare `lde`: PATH may resolve to a different (stale) lde — e.g. CI
--- builds a fresh binary named lde-dev while the nightly sits on PATH.
--- Registry/rocks tools run with `--offline`: they're resolved from the cache
--- at ~/.lde and fail if the package isn't cached, instead of updating the
--- registry on every invocation. When the install used a non-default tree
--- (`--tree`), the wrapper embeds it so its offline lookups hit the tree's
--- caches (registry, git, tar) rather than the default user dir.
---@param toolName string
---@param packageDir string? # nil for rocks: tools (resolved from the registry)
---@param packageName string
function M.writeWrapper(toolName, packageDir, packageName)
	local toolsDir = dirs.getToolsDir()
	const ldeBin = env.execPath() or "lde"
	local treeFlag = ""
	if dirs.getDir() ~= dirs.getUserDir() then
		treeFlag = " --tree '" .. dirs.getDir() .. "'"
	end
	-- sh double-quotes the binary path (spaces), cmd needs its own form below.
	const invocation = packageDir
		and ("\"" .. ldeBin .. "\" x --path '" .. packageDir .. "' " .. packageName .. treeFlag .. " --")
		or ("\"" .. ldeBin .. "\" x" .. treeFlag .. " " .. packageName .. " --offline --")

	if jit.os == "Windows" then
		local wrapperPath = path.join(toolsDir, toolName .. ".cmd")
		-- cmd uses plain double quotes (no backslash escapes like sh), so
		-- paths are wrapped in " directly.
		local winTreeFlag = ""
		if dirs.getDir() ~= dirs.getUserDir() then
			winTreeFlag = " --tree \"" .. dirs.getDir() .. "\""
		end
		const winInvocation = packageDir
			and ('"' .. ldeBin .. '" x --path "' .. packageDir .. '" ' .. packageName .. winTreeFlag .. " --")
			or ('"' .. ldeBin .. '" x' .. winTreeFlag .. " " .. packageName .. " --offline --")
		local content = "@echo off\n" .. winInvocation .. " %*\n"

		-- Skip the write + chmod when the wrapper is already current: repeated
		-- `install rocks:` invocations (and the benchmark's warm runs) would
		-- otherwise pay a subprocess spawn to rewrite an identical file.
		if fs.exists(wrapperPath) and fs.read(wrapperPath) == content then return end

		if not fs.write(wrapperPath, content) then
			lde.error.raise("Failed to write wrapper script: " .. wrapperPath)
		end

		ansi.printf("{green}Installed tool '%s' -> %s", toolName, wrapperPath)
	else
		local wrapperPath = path.join(toolsDir, toolName)
		-- #! needs an absolute path, and /bin/sh is not universal (Termux/Android).
		const shellPath = require("lde-core.global.toolchain").getShellPath()
		local content = "#!" .. shellPath .. "\nexec " .. invocation .. ' "$@"\n'

		-- Skip the write + chmod when the wrapper is already current (see above).
		if fs.exists(wrapperPath) and fs.read(wrapperPath) == content then return end

		if not fs.write(wrapperPath, content) then
			lde.error.raise("Failed to write wrapper script: " .. wrapperPath)
		end

		local child, err = process.spawn("chmod", { "+x", wrapperPath })
		if not child then
			lde.error.raise("Failed to make wrapper executable: " .. (err or "unknown error"))
		end ---@cast child -nil
		child:wait()

		ansi.printf("{green}Installed tool '%s' -> %s", toolName, wrapperPath)
	end
end

return M
