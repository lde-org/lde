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

---@class lde.build.Instance
---@field outDir string
---@field gccBin string
local Instance = {}
Instance.__index = Instance

---@param outDir string
---@param gccBin string
---@return lde.build.Instance
function Instance.new(outDir, gccBin)
	return setmetatable({ outDir = outDir, gccBin = gccBin or "gcc" }, Instance)
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

	local ok, err = fs.copy(full, path.join(self.outDir, dest))
	if not ok then
		error("failed to copy " .. full .. ": " .. err)
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
	local res = os.execute(cmd)
	assert(res == 0 or res == true, "failed to execute " .. cmd)
end

--- Run the C compiler (gcc/mingw on Windows, system gcc elsewhere).
--- On Windows, prepends the mingw bin dir to PATH so subtools (as.exe, ld.exe, etc.) are found.
--- Errors if the compiler exits non-zero.
---@param args string[] # compiler arguments, e.g. {"-c", "foo.c", "-o", "foo.o"}
---@return string stdout
---@return string stderr
function Instance:cc(args)
	local bin = self.gccBin
	local execEnv
	if jit.os == "Windows" and bin ~= "gcc" then
		local mingwBinDir = path.dirname(bin)
		local curPath = os.getenv("PATH") or ""
		if not curPath:find(mingwBinDir, 1, true) then
			execEnv = { PATH = mingwBinDir .. ";" .. curPath }
		end
	end
	local code, stdout, stderr = process.exec(bin, args, execEnv and { env = execEnv } or nil)
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
	local outDir, gccBin, fetch, write, read, extract, copy, delete, move, exists, sh, cc = ...
	local build = {
		outDir  = outDir,
		gccBin  = gccBin,
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
function Instance.setup(state, outputDir, gccBin)
	local inst = Instance.new(outputDir, gccBin or "gcc")
	state:load(GUEST_SOURCE, "@lde-build"):call(
		inst.outDir, inst.gccBin,
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
