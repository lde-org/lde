const curl = require("curl-sys")
const fs = require("fs")
const path = require("path")
const archive = require("archive")
const process = require("process")

-- Minimal lua-sys surface; the full classes live in the lua-sys package dependency.
---@class lua.State
---@field load fun(self: lua.State, code: string, name?: string): lua.Chunk
---@class lua.Chunk
---@field call fun(self: lua.Chunk, ...: any): any

--- Created by lde-core's build-log; lde-build only appends to it.
---@class lde.buildLog.Capture
---@field append fun(self: lde.buildLog.Capture, ...: string?)

---@class lde.build.Instance
---@field outDir string
---@field gccBin string
---@field target string # clang triple for the current build (target triple when cross-compiling, host triple otherwise)
---@field targetFlag string? # clang -target flag when cross-compiling, nil when native
---@field captureLog lde.buildLog.Capture? # non-nil: capture build:sh/build:cc output instead of streaming it
---@field features table<string, boolean> # enabled feature flags, keyed by flag name
const Instance = {}
Instance.__index = Instance

---@param outDir string
---@param gccBin? string # compiler binary; defaults to "gcc"
---@param target? string # triple reported by build:target()/build.target
---@param targetFlag? string # clang -target flag to prepend to every cc invocation
---@param captureLog lde.buildLog.Capture? # non-nil in compact mode: build output is captured (hidden) and dumped to a temp file on failure
function Instance.new(outDir, gccBin, target, targetFlag, captureLog)
	return setmetatable({
		outDir = outDir,
		gccBin = gccBin or "gcc",
		target = target or "unknown",
		targetFlag = targetFlag,
		captureLog = captureLog,
		features = {},
	}, Instance)
end

---@param flags string[]
---@return lde.build.Instance self
function Instance:setFeatures(flags)
	const set = {}
	for _, flag in ipairs(flags) do
		set[flag] = true
	end
	self.features = set
	return self
end

--- The build script sees the same answer as the `features` exclusions the bundler applies.
---@param name string
---@return boolean
function Instance:feature(name)
	return self.features[name] == true
end

---@param url string
function Instance:fetch(url)
	-- Total-time budget: a server that never finishes the body would hang the build.
	local res, err = curl.get(url, { timeout = 120 })
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
	const destAbs = path.join(self.outDir, dest)

	-- Native outputs can be dlopen'd while a rebuild replaces them; copy atomically.
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

--- `*`/`?` stop at a separator, `**` crosses it, and a leading "**/" also matches the scanned dir.
---@param rel string # Relative path at output dir
---@param glob? string # Glob filter, matched against paths relative to rel
---@return string[] # matching paths relative to the output dir, unsorted
function Instance:scan(rel, glob)
	const root = path.normalize(rel)
	local full = path.join(self.outDir, root)
	if not fs.isdir(full) then
		return {}
	end

	-- fs.scan globs absolute paths with the platform separator (unusable on Windows),
	-- so filter here; a leading "**/" needs a second pattern.
	local pattern, rootPattern
	if glob then
		pattern = fs.globToPattern(glob)
		if glob:sub(1, 3) == "**/" then
			rootPattern = fs.globToPattern(glob:sub(4))
		end
	end

	-- fs.scan returns paths relative to the scanned dir; re-rooting on the output dir is a prefix.
	local prefix = root == "." and "" or root .. path.separator
	local files = {}

	for _, child in ipairs(fs.scan(full, "**")) do
		const normalized = child:gsub("\\", "/")
		const isMatch = not pattern or normalized:find(pattern) ~= nil
			or (rootPattern ~= nil and normalized:find(rootPattern) ~= nil)

		if isMatch then
			files[#files + 1] = prefix .. child
		end
	end

	return files
end

---@param cmd string
function Instance:sh(cmd)
	-- Run in the output dir so `build:sh(...)` writes where the rest of the API does.
	-- Compact mode captures output, verbose streams it; both pipes are drained so >64KB
	-- can't deadlock. Pass the command verbatim (`unsafe`, a no-op on POSIX).
	local shell, flag = jit.os == "Windows" ? "cmd" : "sh", jit.os == "Windows" ? "/c" : "-c"
	if self.captureLog then
		local code, stdout, stderr = process.exec(shell, { flag, cmd }, {
			cwd = self.outDir,
			unsafe = true,
			stdout = "pipe",
			stderr = "pipe",
		})
		self.captureLog:append("$ " .. cmd .. "\n", stdout, stderr)
		assert(code == 0, "failed to execute " .. cmd)
		return
	end

	local child, serr = process.spawn(shell, { flag, cmd }, {
		cwd = self.outDir,
		unsafe = true,
		stdout = "inherit",
		stderr = "inherit",
	})
	assert(child, "failed to execute " .. cmd .. ": " .. (serr or "unknown error")) ---@cast child -nil
	local code = child:wait()
	assert(code == 0, "failed to execute " .. cmd)
end

--- Compile with clang, prepending the cross-compile -target flag and (on Windows) the mingw bin dir to PATH.
---@param args string[] # compiler arguments, e.g. {"-c", "foo.c", "-o", "foo.o"}
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
		const curPath = os.getenv("PATH") or ""
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

-- Host methods can't be called across the state boundary with the instance as self.
local GUEST_SOURCE = [==[
	local outDir, gccBin, target, features, fetch, write, read, extract, copy, delete, move, exists, scan, sh, cc = ...
	-- Enabled feature flags, newline-joined: only primitives cross the boundary,
	-- so the host joins the list and the guest splits it back into a set.
	local featureSet = {}
	for flag in features:gmatch("[^\n]+") do
		featureSet[flag] = true
	end
	local build = {
		outDir   = outDir,
		gccBin   = gccBin,
		target   = target,
		features = featureSet,
		fetch    = function(self, url)        return fetch(url)         end,
		write    = function(self, rel, cnt)   write(rel, cnt)           end,
		read     = function(self, rel)        return read(rel)          end,
		extract  = function(self, rel, dest)  extract(rel, dest)        end,
		copy     = function(self, rel, dest)  copy(rel, dest)           end,
		delete   = function(self, rel)        delete(rel)               end,
		move     = function(self, rel, dest)  move(rel, dest)           end,
		exists   = function(self, rel)        return exists(rel)        end,
		scan     = function(self, rel, glob)
			-- Only primitives cross the host boundary, so the host joins the
			-- list and the guest splits it back apart.
			local files = {}
			for file in scan(rel, glob):gmatch("[^\n]+") do
				files[#files + 1] = file
			end
			return files
		end,
		sh       = function(self, cmd)        sh(cmd)                   end,
		cc       = function(self, args)       return cc(unpack(args))   end,
		--- True when the named feature flag is enabled for this build. Build
		--- scripts use this to decide what to emit -- which sources to compile,
		--- which backend .so to produce -- so a package can keep several
		--- backends in one repository and let a feature pick one.
		---@param name string
		---@return boolean
		feature  = function(self, name)       return featureSet[name] == true end,
	}
	package.preload["lde-build"] = function() return build end
	package.preload["lpm-build"] = function() return build end
]==]

--- The instance methods are passed into the guest as varargs; the chunk wires
--- them into the `lde-build` table via package.preload. Only primitives cross.
---@param state     lua.State
---@param outputDir string
---@param gccBin?   string # path to gcc binary; defaults to "gcc"
---@param target?   string # clang triple for build:target() (defaults to "unknown")
---@param targetFlag? string # clang -target flag prepended to cc invocations when cross-compiling
---@param captureLog lde.buildLog.Capture? # non-nil in compact mode: sh/cc output is captured instead of streamed
---@param featureFlags string[]? # enabled feature flags, for build:feature(name)
function Instance.setup(state, outputDir, gccBin, target, targetFlag, captureLog, featureFlags)
	const inst = Instance.new(outputDir, gccBin, target, targetFlag, captureLog)
	table.sort(featureFlags or {})
	inst:setFeatures(featureFlags or {})
	state:load(GUEST_SOURCE, "@lde-build"):call(
		inst.outDir, inst.gccBin, inst.target, table.concat(featureFlags or {}, "\n"),
		function(url)          return inst:fetch(url)     end,
		function(rel, content) inst:write(rel, content)   end,
		rel -> inst:read(rel),
		function(rel, dest)    inst:extract(rel, dest)    end,
		function(rel, dest)    inst:copy(rel, dest)       end,
		function(rel)          inst:delete(rel)           end,
		function(rel, dest)    inst:move(rel, dest)       end,
		rel -> inst:exists(rel),
		|rel, glob| -> table.concat(inst:scan(rel, glob), "\n"),
		function(cmd)          inst:sh(cmd)               end,
		function(...)          return inst:cc({ ... })    end
	)
end

return Instance
