-- Native extension discovery shared by bundle, bloat, and compile: which
-- suffixes a platform loads and how a file below the module dir maps to a
-- module name and to a bundle cpath key.

const fs = require("fs")
const path = require("path")

const features = require("lde-core.package.features")

const nativeext = {}

---@param platform string # sea target platform name
function nativeext.extsFor(platform)
	if platform == "windows" then return { "dll" } end
	if platform == "macos" then return { "so", "dylib" } end
	return { "so" }
end

--- The running host's platform, spelled like a sea target platform.
function nativeext.hostPlatform()
	if jit.os == "Windows" then return "windows" end
	if jit.os == "OSX" then return "macos" end
	return jit.os:lower()
end

---@class lde.nativeext.File
---@field name string # dotted module name, as compile.lua names it
---@field ext string
---@field path string # absolute path
---@field cpath string # key inside the bundle's extracted native dir

--- Walks a package's module dir for native libraries, skipping the same
--- entries a bundle skips: the top-level `tests` dir unless the package is
--- named tests, and paths a feature flag excludes.
---@param modulesDir string
---@param opts { exts: string[], rootName: string, excludesFor: fun(alias: string): string[]? }
function nativeext.scan(modulesDir, opts)
	---@param fileName string
	local function matchExt(fileName)
		for _, ext in ipairs(opts.exts) do
			if fileName:match("%." .. ext .. "$") then
				return ext
			end
		end
		return nil
	end

	---@type lde.nativeext.File[]
	local files = {}

	for entry in fs.readdir(modulesDir) do
		if entry.name == "tests" and opts.rootName ~= "tests" then
			-- A package *named* tests owns its module dir there; every other package's tests must never reach a bundle.
			goto continue
		end

		local entryPath = path.join(modulesDir, entry.name)
		if fs.isdir(entryPath) then
			local excludes = opts.excludesFor(entry.name)
			for _, relativePath in ipairs(fs.scan(entryPath, "**")) do
				local ext = matchExt(relativePath)
				if ext and not features.isExcluded(relativePath, excludes) then
					const relativeName = relativePath:gsub("%." .. ext .. "$", "")
					local name, cpath
					if relativeName == "" then
						name = entry.name
						cpath = entry.name:gsub("%.", "/") .. "." .. ext
					else
						name = entry.name .. "." .. relativeName:gsub(path.separator, ".")
						cpath = (entry.name .. "." .. relativeName):gsub("%.", "/") .. "." .. ext
					end
					files[#files + 1] = {
						name = name,
						ext = ext,
						path = path.join(entryPath, relativePath),
						cpath = cpath,
					}
				end
			end
		else
			local ext = matchExt(entry.name)
			if ext then
				local name = entry.name:gsub("%." .. ext .. "$", "")
				if not features.isExcluded(entry.name, opts.excludesFor(name)) then
					files[#files + 1] = {
						name = name,
						ext = ext,
						path = entryPath,
						cpath = entry.name,
					}
				end
			end
		end

		::continue::
	end

	return files
end

return nativeext
