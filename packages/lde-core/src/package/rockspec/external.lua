--- rockspec `external_dependencies` resolution into the <NAME>_DIR/<NAME>_BINDIR/
--- <NAME>_INCDIR/<NAME>_LIBDIR build variables (LuaRocks' check_external_deps contract).

local fs = require("fs")
local path = require("path")
const env = require("env")

local external = {}

--- Candidate library filenames for `-l<name>`. A bare runtime soname like
--- libyaml-0.so.2 without the unversioned dev symlink cannot be linked, so it is
--- not a candidate.
---@param name string
local function externalLibFiles(name)
	if jit.os == "Windows" then
		return { "lib" .. name .. ".dll.a", name .. ".dll.a", "lib" .. name .. ".a",
			"cyg" .. name .. ".dll", "lib" .. name .. ".dll", name .. ".dll", name .. ".lib" }
	end
	local files = { "lib" .. name .. ".a", "lib" .. name .. ".so" }
	if jit.os == "OSX" then
		files[#files + 1] = "lib" .. name .. ".dylib"
	end
	return files
end

--- LuaRocks only checks "lib"; lib64 (Fedora) and the Debian/Ubuntu multiarch
--- tuple dir (e.g. lib/x86_64-linux-gnu) cover the other common layouts.
---@param prefix string
local function externalLibSubdirs(prefix)
	local subdirs = jit.os == "OSX" and { "lib" } or { "lib64", "lib" }
	if jit.os ~= "Windows" and jit.os ~= "OSX" then
		local iter = fs.readdir(path.join(prefix, "lib"))
		if iter then
			for entry in iter do
				if entry.type == "dir" and entry.name:match("%-linux%-gnu$") then
					subdirs[#subdirs + 1] = path.join("lib", entry.name)
				end
			end
		end
	end
	return subdirs
end

---@param prefix string
---@param subdirs string[]
---@param files string[]
local function findExternalDir(prefix, subdirs, files)
	for _, subdir in ipairs(subdirs) do
		local dirPath = path.join(prefix, subdir)
		for _, file in ipairs(files) do
			if fs.isfile(path.join(dirPath, file)) then return dirPath end
		end
	end
	return nil
end

--- Each declared dependency's required files (library/header/program) are searched
--- under the standard system prefixes, or under an explicit <NAME>_DIR override
--- (e.g. YAML_DIR=/opt/homebrew). A missing dependency must fail here: an
--- unresolvable $(YAML_DIR) substitutes to "" and build tools like luke then read
--- the resulting "YAML_DIR=" argument as a build target.
---@param extDeps table<string, table|string> # spec.external_dependencies
---@param vars table<string, string> # receives NAME_DIR/NAME_BINDIR/NAME_INCDIR/NAME_LIBDIR
---@param packageName string # for the error message
---@return string? err
function external.resolve(extDeps, vars, packageName)
	for name, extFiles in pairs(extDeps) do
		extFiles = type(extFiles) == "table" and extFiles or {}

		local prefixes
		const override = env.var(name .. "_DIR")
		if override then
			prefixes = { override }
		elseif jit.os == "Windows" then
			prefixes = { "c:/external/", "c:/mingw", "c:/windows/system32" }
		else
			prefixes = { "/usr/local", "/usr", "/" }
			if jit.os == "OSX" then table.insert(prefixes, 1, "/opt/homebrew") end
		end

		-- kind -> where to look; mirrors LuaRocks' external_deps_subdirs/patterns.
		---@type { kind: string, subdirs: string[], files: string[] }[]
		const checks = {}
		const library = extFiles.library
		if library then
			local names = type(library) == "table" and library or { library }
			local files = {}
			for _, lib in ipairs(names) do
				for _, f in ipairs(externalLibFiles(lib)) do files[#files + 1] = f end
			end
			checks[#checks + 1] = { kind = "library", subdirs = externalLibSubdirs(prefixes[1]), files = files }
		end
		const header = extFiles.header
		if header then
			local names = type(header) == "table" and header or { header }
			checks[#checks + 1] = { kind = "header", subdirs = { "include" }, files = names }
		end
		const program = extFiles.program
		if program then
			local names = type(program) == "table" and program or { program }
			local files = {}
			for _, p in ipairs(names) do
				files[#files + 1] = jit.os == "Windows" and (p .. ".exe") or p
			end
			checks[#checks + 1] = { kind = "program", subdirs = { "bin" }, files = files }
		end

		-- path.join is a plain concat, so drop the trailing slash from root
		-- prefixes ("/" -> "") to avoid "//lib64" paths.
		---@param rawPrefix string
		local function normalizePrefix(rawPrefix) return (rawPrefix:gsub("/+$", "")) end

		if #checks == 0 then
			-- Empty entry: define the four variables from the first prefix anyway.
			local prefix = normalizePrefix(prefixes[1])
			vars[name .. "_DIR"] = prefix
			vars[name .. "_BINDIR"] = path.join(prefix, "bin")
			vars[name .. "_INCDIR"] = path.join(prefix, "include")
			vars[name .. "_LIBDIR"] = path.join(prefix, "lib")
		else
			-- The first prefix satisfying every check defines the four variables.
			local matched = false
			for _, rawPrefix in ipairs(prefixes) do
				local prefix = normalizePrefix(rawPrefix)
				---@type table<string, string>
				const dirs = {}
				local okAll = true
				for _, check in ipairs(checks) do
					const foundDir = findExternalDir(prefix, check.subdirs, check.files)
					if not foundDir then
						okAll = false
						break
					end
					dirs[check.kind] = foundDir
				end
				if okAll then
					vars[name .. "_DIR"] = prefix
					vars[name .. "_BINDIR"] = dirs.program or path.join(prefix, "bin")
					vars[name .. "_INCDIR"] = dirs.header or path.join(prefix, "include")
					vars[name .. "_LIBDIR"] = dirs.library or path.join(prefix, "lib")
					matched = true
					break
				end
			end

			if not matched then
				const missing = checks[1]
				local tried = {}
				for _, rawPrefix in ipairs(prefixes) do
					local prefix = normalizePrefix(rawPrefix)
					for _, sub in ipairs(missing.subdirs) do
						for _, f in ipairs(missing.files) do
							tried[#tried + 1] = path.join(prefix, sub, f)
						end
					end
				end
				return "Could not find " .. missing.kind .. " file for " .. name
					.. " (tried " .. table.concat(tried, ", ") .. "). " .. name
					.. " is an external dependency of '" .. packageName .. "';"
					.. " install it on your system or set " .. name .. "_DIR=<prefix>"
					.. " so lde can find an existing install."
			end
		end
	end
	return nil
end

return external
