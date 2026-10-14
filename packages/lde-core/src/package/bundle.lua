const fs = require("fs")
const path = require("path")

const features = require("lde-core.package.features")

const lde = require("lde-core")

const stringEscapes = {
	["\\"] = "\\\\",
	['"'] = '\\"',
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
	["\a"] = "\\a",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\v"] = "\\v"
}

---@param s string
local function escapeString(s)
	return (string.gsub(s, '[\\\"\n\r\t\a\b\f\v]', stringEscapes))
end

---@param s string
local function escapeBytes(s)
	return (string.gsub(s, ".", function(c)
		const b = string.byte(c)
		if b >= 32 and b < 127 and c ~= '"' and c ~= '\\' then
			return c
		end
		return string.format("\\x%02x", b)
	end))
end

---@param relativePath string
local function isTestFile(relativePath)
	return relativePath:match("%.test%.lua$") ~= nil
end

---@param content string
---@param chunkName string
local function compileBytecode(content, chunkName)
	const fn, err = loadstring(content, chunkName)
	if not fn then
		lde.error.raise("Failed to compile " .. chunkName .. ": " .. err)
	end ---@cast fn -nil
	return string.dump(fn)
end

---@param projectName string
---@param dir string
---@param out lde.bundle.File[]
---@param excludes string[]? # module-relative globs a feature flag drops
local function bundleDir(projectName, dir, out, excludes)
	for _, relativePath in ipairs(fs.scan(dir, "**" .. path.separator .. "*.lua")) do
		if isTestFile(relativePath) or features.isExcluded(relativePath, excludes) then
			goto continue
		end

		local absPath = path.join(dir, relativePath)
		local content = fs.read(absPath)
		if not content then
			lde.error.raise("Could not read file: " .. absPath)
		end ---@cast content -nil

		local dotted   = relativePath:gsub(path.separator, "."):gsub("%.lua$", "")
		const stripped = dotted:gsub("%.?init$", "")
		---@type string[]
		local names = {}
		if stripped ~= dotted then
			-- X/init.lua answers to both "X" and "X.init"; rocks rely on the second spelling (lgi does require("lgi.init")).
			names[#names + 1] = stripped ~= "" and (projectName .. "." .. stripped) or projectName
			names[#names + 1] = projectName .. "." .. dotted
		else
			names[#names + 1] = projectName .. "." .. dotted
		end

		out[#out + 1] = { names = names, content = content }

		::continue::
	end
end

-- `bin` in the manifest is a path relative to the built modules dir, so "main.lua" is bundled as "<name>.main" and "init.lua" as the package name; without `bin` the entry is src/init.lua (also the package name).
---@param package lde.Package
local function entryModuleName(package)
	local name = package:getName()
	const bin = package:readConfig().bin
	if not bin then return name end

	local dotted = bin:gsub("%.lua$", ""):gsub("%.tl$", ""):gsub("%.moon$", "")
	dotted = dotted:gsub("[/\\]", "."):gsub("%.?init$", "")
	if dotted == "" then return name end
	return name .. "." .. dotted
end

---@param package lde.Package
---@param opts { bytecode: boolean?, raw: boolean?, features: lde.Package.Config.FeatureFlag[]? }?
---@return string|{ name: string, modules: { name: string, code: string }[] }
local function bundlePackage(package, opts)
	opts = opts or {}
	const useBytecode = opts.bytecode or opts.raw
	const raw = opts.raw

	---@class lde.bundle.File
	---@field names string[] # every name this file answers to, best first
	---@field content string

	--- When both spellings of a name exist, package.path resolves ?.lua first, so a rock's plain X.lua must claim the plain name before a directory's init.lua can.
	---@type lde.bundle.File[]
	const topFiles = {}
	---@type lde.bundle.File[]
	local dirFiles = {}
	local modulesDir = package:getModulesDir()
	local mainName = entryModuleName(package)

	-- Each entry in target/ is filtered by the globs its own features turn on, so a package can ship several platform backends but only deploy the one that runs.
	const excludesFor = features.resolverFor(package, opts.features)

	-- Native modules (.so/.dll/.dylib) are embedded as raw bytes and extracted next to the bundle at load time so `require` resolves through package.cpath as in a normal project.
	const nativeExts = jit.os == "Windows" and { "dll" }
		or (jit.os == "OSX" and { "so", "dylib" } or { "so" })
	---@type table<string, string> # cpath-relative path ("cmod/core.so") -> bytes
	const nativeFiles = {}

	for entry in fs.readdir(modulesDir) do
		local p = path.join(modulesDir, entry.name)
		if entry.name == "tests" and package:getName() ~= "tests" then
			-- target/tests is the package's test-only dir and must never end up in a bundle; a package *named* "tests" owns its own module dir there — keep it.
			goto continue
		end

		if fs.isdir(p) then
			const excludes = excludesFor(entry.name)
			bundleDir(entry.name, p, dirFiles, excludes)
			-- Native modules are filtered by the same feature globs, so build:feature(...) and the manifest agree on one set of flags that may drop a backend .so as well as its Lua.
			for _, relativePath in ipairs(fs.scan(p, "**")) do
				local ext = relativePath:match("%.([^.]+)$")
				local isNative = false
				for _, e in ipairs(nativeExts) do
					if ext == e then isNative = true break end
				end
				if isNative and not features.isExcluded(relativePath, excludes) then
					local absPath = path.join(p, relativePath)
					local content = fs.read(absPath)
					if content then
						const relName = relativePath:gsub("%." .. ext .. "$", "")
						local moduleName = relName ~= "" and (entry.name .. "." .. relName) or entry.name
						nativeFiles[moduleName:gsub("%.", "/") .. "." .. ext] = content
					end
				end
			end
		elseif entry.name:match("%.lua$") and not isTestFile(entry.name) then
			-- A rock's flat module (target/X.lua) is keyed by its own name, how a dependency alias spells it in the lockfile.
			if not features.isExcluded(entry.name, excludesFor(entry.name:gsub("%.lua$", ""))) then
				local content = fs.read(p)
				if content then
					local moduleName = entry.name:gsub("%.lua$", "")
					topFiles[#topFiles + 1] = { names = { moduleName }, content = content }
				end
			end
		else
			-- Top-level native module (e.g. lfs.so): embedded like the nested ones and filtered by the same globs.
			local ext = entry.name:match("%.([^.]+)$")
			local isNative = false
			for _, e in ipairs(nativeExts) do
				if ext == e then isNative = true break end
			end
			if isNative and not features.isExcluded(entry.name, excludesFor(entry.name:gsub("%." .. ext .. "$", ""))) then
				local content = fs.read(p)
				if content then
					local moduleName = entry.name:gsub("%." .. ext .. "$", "")
					nativeFiles[moduleName .. "." .. ext] = content
				end
			end
		end
		::continue::
	end

	-- A file keeps its own body under each name: pointing X.init at module "X" would recurse the moment X.lua forwards to X/init.lua, which is exactly what lgi ships.
	---@type table<string, string>
	const files = {}
	---@type table<string, string[]>
	const fileAliases = {}
	---@type table<string, boolean>
	const claimed = {}
	---@param rec lde.bundle.File
	local function claim(rec)
		local primary
		for _, name in ipairs(rec.names) do
			if not claimed[name] then
				claimed[name] = true
				if not primary then
					primary = name
				else
					local list = fileAliases[primary]
					if not list then
						list = {}
						fileAliases[primary] = list
					end
					list[#list + 1] = name
				end
			end
		end
		if primary then files[primary] = rec.content end
	end
	for _, rec in ipairs(topFiles) do claim(rec) end
	for _, rec in ipairs(dirFiles) do claim(rec) end

	if raw then
		-- Each module's bytecode is kept separate so the C side can deserialize it lazily on first require() instead of parsing the whole module graph at startup.
		local modules = {}
		for moduleName, content in pairs(files) do
			modules[#modules + 1] = {
				name = moduleName,
				code = compileBytecode(content, moduleName),
				aliases = fileAliases[moduleName]
			}
		end
		return { name = mainName, modules = modules }
	end

	local parts = {}
	if next(nativeFiles) then
		-- Binary bytes use a short string with \xNN escapes, NOT a long string: the Lua lexer normalizes \r and \r\n to \n inside long strings, which would silently corrupt the .so.
		local entries = {}
		for relPath, content in pairs(nativeFiles) do
			entries[#entries + 1] = string.format('\t["%s"] = "%s"', relPath, escapeBytes(content))
		end
		table.sort(entries)
		parts[#parts + 1] = table.concat({
			"local __lde_native = {",
			table.concat(entries, ",\n"),
			"}",
			"do",
			"\tlocal __lde_sep = package.config:sub(1, 1)",
			'\tlocal __lde_src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")',
			'\tlocal __lde_dir = __lde_src:match("^(.*)[/\\\\]") or "."',
			'\tlocal __lde_libdir = __lde_dir .. __lde_sep .. ".lde-native"',
			"\tlocal __lde_mkdir = function(d)",
			'\t\tif __lde_sep == "/" then',
			'\t\t\tos.execute(\'mkdir -p "\' .. d .. \'"\')',
			"\t\telse",
			'\t\t\tos.execute(\'mkdir "\' .. d .. \'"\')',
			"\t\tend",
			"\tend",
			"\t__lde_mkdir(__lde_libdir)",
			"\tfor __lde_name, __lde_bytes in pairs(__lde_native) do",
			'\t\tlocal __lde_file = __lde_libdir .. __lde_sep .. __lde_name:gsub("/", __lde_sep)',
			'\t\tlocal __lde_d = __lde_file:match("^(.*)[/\\\\]")',
			"\t\tif __lde_d and __lde_d ~= __lde_libdir then __lde_mkdir(__lde_d) end",
			'\t\tlocal __lde_f = assert(io.open(__lde_file, "wb"))',
			"\t\t__lde_f:write(__lde_bytes)",
			"\t\t__lde_f:close()",
			"\tend",
			'\tpackage.cpath = __lde_libdir .. __lde_sep .. "?.so;" .. __lde_libdir .. __lde_sep .. "?.dll;" .. __lde_libdir .. __lde_sep .. "?.dylib;" .. package.cpath',
			"end",
		}, "\n") .. "\n"
	end
	for moduleName, content in pairs(files) do
		if useBytecode then
			content = escapeBytes(compileBytecode(content, moduleName))
		else
			content = escapeString(content)
		end

		local loader
		if moduleName == mainName then
			-- Loaded eagerly so the final call can pass args through.
			loader = string.format('load("%s", "@%s")', content, moduleName)
		else
			-- Defer deserialization to first require() so trivial commands don't pay for the whole module graph; the modname vararg is forwarded because modules use (...), e.g. lde-core sets package.loaded[(...)] = lde.
			loader = string.format('function(...) return load("%s", "@%s")(...) end', content, moduleName)
		end

		-- Aliases (X/init.lua answers to "X" and "X.init") share one loader: emitting the file twice would double its bytes, and aliasing to package.preload[moduleName] would recurse when a sibling X.lua owns that name.
		local list = fileAliases[moduleName]
		if list and #list > 0 then
			const var = "__lde_load_" .. moduleName:gsub("%W", "_")
			parts[#parts + 1] = "local " .. var .. " = " .. loader
			parts[#parts + 1] = string.format('package.preload["%s"] = %s', moduleName, var)
			for _, alias in ipairs(list) do
				parts[#parts + 1] = string.format('package.preload["%s"] = %s', alias, var)
			end
		else
			parts[#parts + 1] = string.format('package.preload["%s"] = %s', moduleName, loader)
		end
	end

	parts[#parts + 1] = string.format('return package.preload["%s"](...)', mainName)

	local result = table.concat(parts, "\n") .. "\n"

	if useBytecode then
		result = compileBytecode(result, package:getName())
	end

	return result
end

return bundlePackage
