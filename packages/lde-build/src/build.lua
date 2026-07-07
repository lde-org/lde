local curl = require("curl-sys")
local fs = require("fs")
local path = require("path")
local archive = require("archive")
local process = require("process")

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

--- Inject an lde-build instance into a lua.State as require("lde-build").
--- All I/O methods are registered as host callbacks; the guest calls them
--- via the cross-state bridge. No guest-side Lua source needed — the instance
--- table is built entirely from host functions registered as guest globals,
--- then assembled into a table in the guest via state:load().
---@param state    lua.State
---@param outputDir string
---@param gccBin?  string  # path to gcc binary; defaults to "gcc"
function Instance.setup(state, outputDir, gccBin)
	local inst = Instance.new(outputDir, gccBin or "gcc")
	local g = state:globals()

	-- Register each method as a named host callback global, then assemble
	-- the build table in guest Lua and expose it via package.preload.
	g._lde_build_outDir  = outputDir
	g._lde_build_gccBin  = inst.gccBin
	g._lde_build_fetch   = function(url)           return inst:fetch(url)       end
	g._lde_build_write   = function(rel, content)  inst:write(rel, content)     end
	g._lde_build_read    = function(rel)            return inst:read(rel)        end
	g._lde_build_extract = function(rel, dest)      inst:extract(rel, dest)     end
	g._lde_build_copy    = function(rel, dest)      inst:copy(rel, dest)        end
	g._lde_build_delete  = function(rel)            inst:delete(rel)            end
	g._lde_build_move    = function(rel, dest)      inst:move(rel, dest)        end
	g._lde_build_exists  = function(rel)            return inst:exists(rel)     end
	g._lde_build_sh      = function(cmd)            inst:sh(cmd)               end
	g._lde_build_cc      = function(args)           return inst:cc(args)       end

	state:load([[
		local _build = {
			outDir   = _lde_build_outDir,
			gccBin   = _lde_build_gccBin,
			fetch    = function(self, url)        return _lde_build_fetch(url)         end,
			write    = function(self, rel, cnt)   _lde_build_write(rel, cnt)           end,
			read     = function(self, rel)        return _lde_build_read(rel)          end,
			extract  = function(self, rel, dest)  _lde_build_extract(rel, dest)        end,
			copy     = function(self, rel, dest)  _lde_build_copy(rel, dest)           end,
			delete   = function(self, rel)        _lde_build_delete(rel)               end,
			move     = function(self, rel, dest)  _lde_build_move(rel, dest)           end,
			exists   = function(self, rel)        return _lde_build_exists(rel)        end,
			sh       = function(self, cmd)        _lde_build_sh(cmd)                   end,
			cc       = function(self, args)       return _lde_build_cc(args)           end,
		}
		package.preload["lde-build"] = function() return _build end
		package.preload["lpm-build"] = function() return _build end
	]])
end

return Instance
