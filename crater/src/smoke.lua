-- crater/src/smoke.lua
--
-- Crater codegen: writes each package's scratch project, discovers the modules
-- lde materialized into target/, and generates the smoke script that requires
-- every module and runs the functional checks.
--
-- The generated script speaks a line protocol parsed by crater/src/init.lua:
--   OK<TAB>module             module required cleanly
--   FUNC<TAB>module           module required and its functional check passed
--   FUNCERR<TAB>module<TAB>e  functional check failed (warning, recorded error)
--   ERR<TAB>module<TAB>error  require failed (recorded error)

local fs = require("fs")
local path = require("path")
local json = require("json")
local packages = require("crater.packages")

local EXCLUDE_MODULES = packages.EXCLUDE_MODULES
local EXCLUDE_PREFIXES = packages.EXCLUDE_PREFIXES
local EXERCISES = packages.EXERCISES

--- Deep-stub shim for a global that only exists in a specific runtime
--- (e.g. neovim's `vim`). Any read returns a per-key stub table, any write is
--- dropped, and calling it returns nil. Note: LuaJIT strips the metatable when
--- __index returns a table whose own __index is the *same* function (its
--- self-reference guard), so each stub level needs a fresh closure identity.
---@param global string
local function deepStubSource(global)
	return string.format([[
do
	local stubCache = {}
	local function newStub()
		local mt = {
			__index = function(_, k)
				local v = stubCache[k]
				if not v then
					v = newStub()
					stubCache[k] = v
				end
				return v
			end,
			__newindex = function() end,
			__call = function() return nil end,
		}
		return setmetatable({}, mt)
	end
	%s = newStub()
end
]], global)
end

--- Create a fresh smoke project for one package.
---@param dir string
---@param name string
---@param extra string[]?
local function makeProject(dir, name, extra)
	if not fs.isdir(dir) then
		fs.mkdirAll(path.join(dir, "src"))
		fs.write(path.join(dir, "src", "init.lua"), "return {}\n")
		local deps = { [name] = { luarocks = name } }
		for _, dep in ipairs(extra or {}) do
			deps[dep] = { luarocks = dep }
		end
		fs.write(path.join(dir, "lde.json"), json.encode({
			name = name .. "-smoke",
			version = "0.1.0",
			dependencies = deps,
		}))
	end
end

--- Discover modules materialized into target/: `a.lua` -> "a", `a/b.lua` -> "a.b",
--- `a/init.lua` -> "a", `a/b.so` -> "a.b". Skips dependency dirs (which hold bin
--- scripts) and the smoke project's own output dir.
---@param targetDir string
---@param exclude table<string, boolean>
---@return string[]
local function discoverModules(targetDir, exclude)
	local seen, mods = {}, {}
	---@param rel string
	local function add(rel)
		local parts = {}
		for seg in rel:gmatch("[^/]+") do
			parts[#parts + 1] = seg
		end
		if #parts == 0 or exclude[parts[1]] then return end
		local name
		local last = parts[#parts]
		if last == "init.lua" then
			name = table.concat(parts, ".", 1, #parts - 1)
			if name == "" then return end
		else
			parts[#parts] = last:gsub("%.lua$", ""):gsub("%.so$", ""):gsub("%.dll$", "")
			name = table.concat(parts, ".")
		end
		if not seen[name] then
			seen[name] = true
			mods[#mods + 1] = name
		end
	end
	for _, glob in ipairs({ "**/*.lua", "**/*.so", "**/*.dll" }) do
		for _, rel in ipairs(fs.scan(targetDir, glob)) do add(rel) end
	end
	table.sort(mods)
	return mods
end

--- Generate the smoke script: shims, then require every module + functional checks.
---@param mods string[]
---@param shims string[]?
---@return string
---@return number excluded  -- number of discovered modules that were skipped
local function makeMainLua(mods, shims)
	local excluded = 0
	local lines = {
		-- LuaJIT's print() doesn't flush on POSIX pipes and os.exit() skips the
		-- stdio flush, which would silently truncate results; force line buffering.
		"io.stdout:setvbuf('line')",
		"io.stderr:setvbuf('line')",
		-- Modules like luacheck.main call os.exit() at require time (CLI entry
		-- point); turn that into a catchable error so one module can't kill the
		-- whole smoke run.
		"local realExit = os.exit",
		"os.exit = function(code) error('module called os.exit(' .. tostring(code) .. ')', 0) end",
		"local failures = 0",
		"local function report(kind, name, extra)",
		"  if kind == \"OK\" then print(\"OK\\t\" .. name) else failures = failures + 1 print(\"ERR\\t\" .. name .. \"\\t\" .. tostring(extra):gsub(\"[\\r\\n]+\", \" \")) end",
		"end",
	}
	for _, shim in ipairs(shims or {}) do
		lines[#lines + 1] = deepStubSource(shim)
	end

	for _, name in ipairs(mods) do
		if EXCLUDE_MODULES[name] then
			excluded = excluded + 1
		else
			local skippedByPrefix = false
			for _, prefix in ipairs(EXCLUDE_PREFIXES) do
				if name:sub(1, #prefix) == prefix then
					skippedByPrefix = true
					break
				end
			end
			if skippedByPrefix then
				excluded = excluded + 1
			else
				local check = EXERCISES[name]
				if check then
					lines[#lines + 1] = string.format(
						"local ok, m = pcall(require, %q) if ok then local fok, ferr = pcall(function(m) return %s end, m) if fok and ferr then print(\"FUNC\\t%s\") else failures = failures + 1 print(\"FUNCERR\\t%s\\t\" .. tostring(ferr)) end else report(\"ERR\", %q, m) end",
						name, check, name, name, name)
				else
					lines[#lines + 1] = string.format("do local ok, m = pcall(require, %q) if ok then report(\"OK\", %q) else report(\"ERR\", %q, m) end end",
						name, name, name)
				end
			end
		end
	end
	lines[#lines + 1] = "if failures > 0 then realExit(1) end"
	return table.concat(lines, "\n") .. "\n", excluded
end

return {
	makeProject = makeProject,
	discoverModules = discoverModules,
	makeMainLua = makeMainLua,
}
