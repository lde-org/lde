local curl = require("curl-sys")
local fs = require("fs")
local path = require("path")
local archive = require("archive")

---@class lde.build.Instance
---@field outDir string
local Instance = {}
Instance.__index = Instance

---@param outDir string
---@return lde.build.Instance
function Instance.new(outDir)
	return setmetatable({ outDir = outDir }, Instance)
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

--- Inject an lde-build instance into a lua.State as require("lde-build").
--- All I/O methods are registered as host callbacks; the guest calls them
--- via the cross-state bridge. No guest-side Lua source needed — the instance
--- table is built entirely from host functions registered as guest globals,
--- then assembled into a table in the guest via state:load().
---@param state    lua.State
---@param outputDir string
function Instance.setup(state, outputDir)
	local inst = Instance.new(outputDir)
	local g = state:globals()

	-- Register each method as a named host callback global, then assemble
	-- the build table in guest Lua and expose it via package.preload.
	g._lde_build_outDir  = outputDir
	g._lde_build_fetch   = function(url)           return inst:fetch(url)       end
	g._lde_build_write   = function(rel, content)  inst:write(rel, content)     end
	g._lde_build_read    = function(rel)            return inst:read(rel)        end
	g._lde_build_extract = function(rel, dest)      inst:extract(rel, dest)     end
	g._lde_build_copy    = function(rel, dest)      inst:copy(rel, dest)        end
	g._lde_build_delete  = function(rel)            inst:delete(rel)            end
	g._lde_build_move    = function(rel, dest)      inst:move(rel, dest)        end
	g._lde_build_exists  = function(rel)            return inst:exists(rel)     end
	g._lde_build_sh      = function(cmd)            inst:sh(cmd)               end

	state:load([[
		local _build = {
			outDir   = _lde_build_outDir,
			fetch    = function(self, url)        return _lde_build_fetch(url)         end,
			write    = function(self, rel, cnt)   _lde_build_write(rel, cnt)           end,
			read     = function(self, rel)        return _lde_build_read(rel)          end,
			extract  = function(self, rel, dest)  _lde_build_extract(rel, dest)        end,
			copy     = function(self, rel, dest)  _lde_build_copy(rel, dest)           end,
			delete   = function(self, rel)        _lde_build_delete(rel)               end,
			move     = function(self, rel, dest)  _lde_build_move(rel, dest)           end,
			exists   = function(self, rel)        return _lde_build_exists(rel)        end,
			sh       = function(self, cmd)        _lde_build_sh(cmd)                   end,
		}
		package.preload["lde-build"] = function() return _build end
		package.preload["lpm-build"] = function() return _build end
	]])
end

return Instance
