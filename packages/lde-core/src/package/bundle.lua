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
---@param files table<string, string>
local function bundleDir(projectName, dir, files)
	for _, relativePath in ipairs(fs.scan(dir, "**" .. path.separator .. "*.lua")) do
		if isTestFile(relativePath) then
			goto continue
		end

		local absPath = path.join(dir, relativePath)
		local content = fs.read(absPath)
		if not content then
			lde.error.raise("Could not read file: " .. absPath)
		end

		local moduleName = relativePath:gsub(path.separator, "."):gsub("%.lua$", ""):gsub("%.?init$", "")
		if moduleName ~= "" then
			moduleName = projectName .. "." .. moduleName
		else
			moduleName = projectName
		end

		files[moduleName] = content

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

	local files = {}
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
			bundleDir(entry.name, p, files)
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
				files[moduleName] = content
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
				code = compileBytecode(content, moduleName)
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

		if moduleName == mainName then
			-- Main entry: loaded eagerly so the final call can pass args through.
			parts[#parts + 1] = string.format(
				'package.preload["%s"] = load("%s", "@%s")',
				moduleName, content, moduleName
			)
		else
			-- Everything else: defer bytecode deserialization to first require(),
			-- so trivial commands (--version, help) don't pay for the whole
			-- module graph at startup. Forward the modname vararg that require
			-- passes to preload loaders: modules use (...), e.g. lde-core does
			-- package.loaded[(...)] = lde at the top.
			parts[#parts + 1] = string.format(
				'package.preload["%s"] = function(...) return load("%s", "@%s")(...) end',
				moduleName, content, moduleName
			)
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
