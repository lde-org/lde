local fs = require("fs")
local path = require("path")

local lde = require("lde-core")

local stringEscapes = {
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
---@return string
local function escapeString(s)
	return (string.gsub(s, '[\\\"\n\r\t\a\b\f\v]', stringEscapes))
end

---@param s string
---@return string
local function escapeBytes(s)
	return (string.gsub(s, ".", function(c)
		local b = string.byte(c)
		if b >= 32 and b < 127 and c ~= '"' and c ~= '\\' then
			return c
		end
		return string.format("\\x%02x", b)
	end))
end

---@param relativePath string
---@return boolean
local function isTestFile(relativePath)
	return relativePath:match("%.test%.lua$") ~= nil
end

---@param content string
---@param chunkName string
---@return string
local function compileBytecode(content, chunkName)
	local fn, err = loadstring(content, chunkName)
	if not fn then
		lde.error.raise("Failed to compile " .. chunkName .. ": " .. err)
	end ---@cast fn -nil
	return string.dump(fn)
end

---@param projectName string
---@param dir string
---@param out lde.bundle.File[]
local function bundleDir(projectName, dir, out)
	for _, relativePath in ipairs(fs.scan(dir, "**" .. path.separator .. "*.lua")) do
		if isTestFile(relativePath) then
			goto continue
		end

		local absPath = path.join(dir, relativePath)
		local content = fs.read(absPath)
		if not content then
			lde.error.raise("Could not read file: " .. absPath)
		end

		local dotted   = relativePath:gsub(path.separator, "."):gsub("%.lua$", "")
		local stripped = dotted:gsub("%.?init$", "")
		---@type string[]
		local names = {}
		if stripped ~= dotted then
			-- X/init.lua answers to both "X" and "X.init" through package.path,
			-- so the bundle has to preload both names. Rocks rely on the second
			-- spelling: lgi explicitly does require("lgi.init").
			names[#names + 1] = stripped ~= "" and (projectName .. "." .. stripped) or projectName
			names[#names + 1] = projectName .. "." .. dotted
		else
			names[#names + 1] = projectName .. "." .. dotted
		end

		out[#out + 1] = { names = names, content = content }

		::continue::
	end
end

---@param package lde.Package
---@param opts { bytecode: boolean?, raw: boolean? }?
---@return string|{ name: string, modules: { name: string, code: string }[] }
local function bundlePackage(package, opts)
	opts = opts or {}
	local useBytecode = opts.bytecode or opts.raw
	local raw = opts.raw

	---@class lde.bundle.File
	---@field names string[] # every name this file answers to, best first
	---@field content string

	--- Files directly under target/ (a rock's X.lua) and files found inside a
	--- package directory (target/<pkg>/X.lua) are collected separately: when
	--- both spellings of one name exist, package.path resolves ?.lua first, so
	--- the plain file has to claim the plain name before the directory's
	--- init.lua can.
	---@type lde.bundle.File[]
	local topFiles = {}
	---@type lde.bundle.File[]
	local dirFiles = {}
	local modulesDir = package:getModulesDir()

	-- Native modules (.so/.dll/.dylib): embedded as raw bytes and extracted
	-- next to the bundle at load time, so `require("cmod.core")` resolves
	-- through package.cpath like it does in a normal lde project.
	local nativeExts = jit.os == "Windows" and { "dll" }
		or (jit.os == "OSX" and { "so", "dylib" } or { "so" })
	---@type table<string, string> # cpath-relative path ("cmod/core.so") -> bytes
	local nativeFiles = {}

	for entry in fs.readdir(modulesDir) do
		local p = path.join(modulesDir, entry.name)
		if entry.name == "tests" and package:getName() ~= "tests" then
			-- lde test exposes the package's tests/ dir as target/tests; it's
			-- test-only code and must never end up in a bundle. A package
			-- *named* "tests" has its own module dir at target/tests — keep it.
			goto continue
		end

		if fs.isdir(p) then
			bundleDir(entry.name, p, dirFiles)
			for _, relativePath in ipairs(fs.scan(p, "**")) do
				local ext = relativePath:match("%.([^.]+)$")
				local isNative = false
				for _, e in ipairs(nativeExts) do
					if ext == e then isNative = true break end
				end
				if isNative then
					local absPath = path.join(p, relativePath)
					local content = fs.read(absPath)
					if content then
						local relName = relativePath:gsub("%." .. ext .. "$", "")
						local moduleName = relName ~= "" and (entry.name .. "." .. relName) or entry.name
						nativeFiles[moduleName:gsub("%.", "/") .. "." .. ext] = content
					end
				end
			end
		elseif entry.name:match("%.lua$") and not isTestFile(entry.name) then
			local content = fs.read(p)
			if content then
				local moduleName = entry.name:gsub("%.lua$", "")
				topFiles[#topFiles + 1] = { names = { moduleName }, content = content }
			end
		else
			-- Top-level native module (e.g. lfs.so from a rock that installs a
			-- single module into target/): embedded like the nested ones.
			local ext = entry.name:match("%.([^.]+)$")
			local isNative = false
			for _, e in ipairs(nativeExts) do
				if ext == e then isNative = true break end
			end
			if isNative then
				local content = fs.read(p)
				if content then
					local moduleName = entry.name:gsub("%." .. ext .. "$", "")
					nativeFiles[moduleName .. "." .. ext] = content
				end
			end
		end
		::continue::
	end

	-- Give every file one primary name plus any remaining aliases. A file keeps
	-- its own body under each of them: pointing X.init at module "X" instead
	-- would recurse the moment X.lua is a forwarder to X/init.lua, which is
	-- exactly what lgi ships.
	---@type table<string, string>
	local files = {}
	---@type table<string, string[]>
	local fileAliases = {}
	---@type table<string, boolean>
	local claimed = {}
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

	local mainName = package:getName()

	if raw then
		-- Raw bytecode table for sea.compile: each module's bytecode is kept
		-- separate so the C side can embed it as raw bytes and deserialize it
		-- lazily on first require(), instead of parsing/deserializing the whole
		-- module graph at startup.
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
		-- Extract embedded native libraries next to the bundle and put the
		-- directory on package.cpath before any module loads.
		--
		-- Binary bytes are embedded as a short string with \xNN escapes, NOT a
		-- long string: the Lua lexer normalizes \r and \r\n to \n inside long
		-- strings, which would silently corrupt the .so.
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
			-- Main entry: loaded eagerly so the final call can pass args through.
			loader = string.format('load("%s", "@%s")', content, moduleName)
		else
			-- Everything else: defer bytecode deserialization to first require(),
			-- so trivial commands (--version, help) don't pay for the whole
			-- module graph at startup. Forward the modname vararg that require
			-- passes to preload loaders: modules use (...), e.g. lde-core does
			-- package.loaded[(...)] = lde at the top.
			loader = string.format('function(...) return load("%s", "@%s")(...) end', content, moduleName)
		end

		-- A module with preload aliases (X/init.lua answers to "X" and
		-- "X.init") shares one loader between the names: emitting the file twice
		-- would double its bytes, and aliasing to package.preload[moduleName]
		-- would recurse when a sibling X.lua owns that name.
		local list = fileAliases[moduleName]
		if list and #list > 0 then
			local var = "__lde_load_" .. moduleName:gsub("%W", "_")
			parts[#parts + 1] = "local " .. var .. " = " .. loader
			parts[#parts + 1] = string.format('package.preload["%s"] = %s', moduleName, var)
			for _, alias in ipairs(list) do
				parts[#parts + 1] = string.format('package.preload["%s"] = %s', alias, var)
			end
		else
			parts[#parts + 1] = string.format('package.preload["%s"] = %s', moduleName, loader)
		end
	end

	parts[#parts + 1] = string.format('return package.preload["%s"](...)', package:getName())

	local result = table.concat(parts, "\n") .. "\n"

	if useBytecode then
		result = compileBytecode(result, package:getName())
	end

	return result
end

return bundlePackage
