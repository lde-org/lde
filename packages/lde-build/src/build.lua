local curl = require("curl-sys")
local fs = require("fs")
local path = require("path")
local archive = require("archive")
local process = require("process")

-- Minimal lua-sys surface used here (the full classes live in the lua-sys
-- package, which is a dependency of the caller, not of lde-build).
---@class lua.State
---@field load fun(self: lua.State, code: string, name?: string): lua.Chunk
---@class lua.Chunk
---@field call fun(self: lua.Chunk, ...: any): any

--- Capture buffer for hidden build output (created by lde-core's build-log;
--- lde-build only ever appends to it).
---@class lde.buildLog.Capture
---@field append fun(self: lde.buildLog.Capture, ...: string?)

---@class lde.build.Instance
---@field outDir string
---@field gccBin string
---@field target string # clang triple for the current build (target triple when cross-compiling, host triple otherwise)
---@field targetFlag string? # clang -target flag when cross-compiling, nil when native
---@field captureLog lde.buildLog.Capture? # non-nil: capture build:sh/build:cc output instead of streaming it
local Instance = {}
Instance.__index = Instance

---@param outDir string
---@param gccBin? string # compiler binary; defaults to "gcc"
---@param target? string # triple reported by build:target()/build.target
---@param targetFlag? string # clang -target flag to prepend to every cc invocation
---@param captureLog lde.buildLog.Capture? # non-nil in compact mode: build output is captured (hidden) and dumped to a temp file on failure
---@return lde.build.Instance
function Instance.new(outDir, gccBin, target, targetFlag, captureLog)
	return setmetatable({
		outDir = outDir,
		gccBin = gccBin or "gcc",
		target = target or "unknown",
		targetFlag = targetFlag,
		captureLog = captureLog,
	}, Instance)
end

---@param url string
---@return string
function Instance:fetch(url)
	local res, err = curl.get(url)
	if not res then
		error("failed to fetch " .. url .. ": " .. err)
	end

	return res.body
end

---@param rel string # Relative path at output dir
---@param content string
function Instance:write(rel, content)
	local full = path.join(self.outDir, rel)
	fs.mkdirAll(path.dirname(full))
	assert(fs.write(full, content), "failed to write " .. full)
end

---@param rel string # Relative path at output dir
---@return string
function Instance:read(rel)
	local full = path.join(self.outDir, rel)
	local res = fs.read(full)
	assert(res, "failed to read " .. full)
	return res
end

---@param rel string # Relative path at output dir
---@param dest string # Relative path at output dir
function Instance:extract(rel, dest)
	local full = path.join(self.outDir, rel)

	local ok, err = archive.new(full):extract(path.join(self.outDir, dest))
	if not ok then
		error("failed to extract " .. full .. ": " .. err)
	end
end

---@param rel string # Relative path at output dir
---@param dest string # Relative path at output dir
function Instance:copy(rel, dest)
	local full = path.join(self.outDir, rel)
	local destAbs = path.join(self.outDir, dest)

	-- Build outputs (native .so/.dll files) can be dlopen'd by the running
	-- process while a rebuild replaces them; copy atomically (temp + rename)
	-- so a live mapping is never truncated underneath it. Directories keep the
	-- plain recursive copy.
	local ok, err
	if fs.isfile(full) then
		ok = fs.copyAtomic(full, destAbs)
	else
		ok, err = fs.copy(full, destAbs)
	end

	if not ok then
		error("failed to copy " .. full .. ": " .. (err or "copy failed"))
	end
end

---@param rel string # Relative path at output dir
function Instance:delete(rel)
	local full = path.join(self.outDir, rel)

	local ok, err = fs.delete(full)
	if not ok then
		error("failed to remove " .. full .. ": " .. err)
	end
end

---@param rel string # Relative path at output dir
---@param dest string # Relative path at output dir
function Instance:move(rel, dest)
	local full = path.join(self.outDir, rel)

	local ok, err = fs.move(full, path.join(self.outDir, dest))
	if not ok then
		error("failed to move " .. full .. ": " .. err)
	end
end

---@param rel string # Relative path at output dir
function Instance:exists(rel)
	local full = path.join(self.outDir, rel)
	return fs.exists(full)
end

---@param cmd string
function Instance:sh(cmd)
	-- Run relative to the output dir so `build:sh("echo x > out.txt")` lands
	-- where the rest of the build API writes. Compact mode captures the output
	-- (hidden from the user, dumped to a temp file if the build fails) so
	-- configure-style scripts can't flood the terminal; verbose mode streams
	-- it live to keep the current behavior. Both stdout and stderr are piped
	-- so the concurrent fd drain (readFds) can't deadlock on >64KB output.
	if self.captureLog then
		local shell, flag = jit.os == "Windows" and "cmd" or "sh", jit.os == "Windows" and "/c" or "-c"
		local code, stdout, stderr = process.exec(shell, { flag, cmd }, {
			cwd = self.outDir,
			stdout = "pipe",
			stderr = "pipe",
		})
		self.captureLog:append("$ " .. cmd .. "\n", stdout, stderr)
		assert(code == 0, "failed to execute " .. cmd)
		return
	end

	local shell, flag = jit.os == "Windows" and "cmd" or "sh", jit.os == "Windows" and "/c" or "-c"
	local child, serr = process.spawn(shell, { flag, cmd }, {
		cwd = self.outDir,
		stdout = "inherit",
		stderr = "inherit",
	})
	assert(child, "failed to execute " .. cmd .. ": " .. (serr or "unknown error")) ---@cast child -nil
	local code = child:wait()
	assert(code == 0, "failed to execute " .. cmd)
end

--- Run the C compiler (clang on most systems; mingw clang on Windows).
--- When cross-compiling, prepends the clang -target flag so the code is
--- compiled for the target platform.
--- On Windows, prepends the mingw bin dir to PATH so subtools (as.exe, ld.exe, etc.) are found.
--- Errors if the compiler exits non-zero.
---@param args string[] # compiler arguments, e.g. {"-c", "foo.c", "-o", "foo.o"}
---@return string stdout
---@return string stderr
function Instance:cc(args)
	local bin = self.gccBin
	local execArgs = args
	if self.targetFlag then
		execArgs = { self.targetFlag }
		for _, arg in ipairs(args) do execArgs[#execArgs + 1] = arg end
	end
	local execEnv
	if jit.os == "Windows" and bin ~= "gcc" then
		local mingwBinDir = path.dirname(bin)
		local curPath = os.getenv("PATH") or ""
		if not curPath:find(mingwBinDir, 1, true) then
			execEnv = { PATH = mingwBinDir .. ";" .. curPath }
		end
	end
	local code, stdout, stderr = process.exec(bin, execArgs, {
		cwd = self.outDir,
		env = execEnv,
	})
	if self.captureLog then self.captureLog:append(stdout or "", stderr or "") end
	assert(code == 0, "cc failed: " .. (stderr or stdout or ""))
	return stdout or "", stderr or ""
end

-- ─── Guest-side assembly ─────────────────────────────────────────────────
--
-- The build table scripts see via require("lde-build") is assembled guest-
-- side. The host methods can't be called across the state boundary with the
-- instance as self, so setup() passes them in as host callbacks (varargs);
-- this chunk wires them into the table, forwarding calls. `cc` receives its
-- argument table already unpacked — only primitives cross host↔guest.
local GUEST_SOURCE = [==[
	local outDir, gccBin, target, fetch, write, read, extract, copy, delete, move, exists, sh, cc = ...
	local build = {
		outDir  = outDir,
		gccBin  = gccBin,
		target  = target,
		fetch   = function(self, url)        return fetch(url)         end,
		write   = function(self, rel, cnt)   write(rel, cnt)           end,
		read    = function(self, rel)        return read(rel)          end,
		extract = function(self, rel, dest)  extract(rel, dest)        end,
		copy    = function(self, rel, dest)  copy(rel, dest)           end,
		delete  = function(self, rel)        delete(rel)               end,
		move    = function(self, rel, dest)  move(rel, dest)           end,
		exists  = function(self, rel)        return exists(rel)        end,
		sh      = function(self, cmd)        sh(cmd)                   end,
		cc      = function(self, args)       return cc(unpack(args))   end,
	}
	package.preload["lde-build"] = function() return build end
	package.preload["lpm-build"] = function() return build end
]==]

--- Inject an lde-build instance into a lua-sys guest state.
---
--- The instance methods are registered as host callbacks and passed into the
--- guest as varargs; the guest chunk assembles them into the `lde-build`
--- table via package.preload. No globals cross the boundary.
---@param state     lua.State
---@param outputDir string
---@param gccBin?   string # path to gcc binary; defaults to "gcc"
---@param target?   string # clang triple for build:target() (defaults to "unknown")
---@param targetFlag? string # clang -target flag prepended to cc invocations when cross-compiling
---@param captureLog lde.buildLog.Capture? # non-nil in compact mode: sh/cc output is captured instead of streamed
function Instance.setup(state, outputDir, gccBin, target, targetFlag, captureLog)
	local inst = Instance.new(outputDir, gccBin, target, targetFlag, captureLog)
	state:load(GUEST_SOURCE, "@lde-build"):call(
		inst.outDir, inst.gccBin, inst.target,
		function(url)          return inst:fetch(url)     end,
		function(rel, content) inst:write(rel, content)   end,
		function(rel)          return inst:read(rel)      end,
		function(rel, dest)    inst:extract(rel, dest)    end,
		function(rel, dest)    inst:copy(rel, dest)       end,
		function(rel)          inst:delete(rel)           end,
		function(rel, dest)    inst:move(rel, dest)       end,
		function(rel)          return inst:exists(rel)    end,
		function(cmd)          inst:sh(cmd)               end,
		function(...)          return inst:cc({ ... })    end
	)
end

return Instance
