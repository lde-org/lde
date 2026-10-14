-- Guest-side infrastructure for `lde run --hot` / `lde run --watch`, evaluated once per guest state before the entry point runs.
return [==[
local hot = ...

local M = {
	fileModules = {}, -- normalized source key -> { [modname] = true }
	moduleFile  = {}, -- modname -> normalized source key
	dependents  = {}, -- modname -> { [dependent] = true }
	lastReloaded = {},
	accepts     = {}, -- owner -> { fn, ... } (see acceptOwner)

	pendingCallbacks   = {},
	pendingNames       = {},
	pendingCallbackSet = {},
	pendingNameSet     = {},
}

local ENTRY_OWNER = "@entry"

local function canonicalKey(key)
	if key:sub(1, 4) == "src:" then
		return (key:gsub("%.tl$", ".lua"):gsub("%.moon$", ".lua"))
	end
	return key
end

local function normKey(p)
	local t = hot.targetPrefix
	if t and p:sub(1, #t) == t then
		return canonicalKey("src:" .. p:sub(#t + 1))
	end
	local s = hot.srcPrefix
	if s and p:sub(1, #s) == s then
		return canonicalKey("src:" .. p:sub(#s + 1))
	end
	return p
end

local searchers = package.searchers or package.loaders
local origLuaSearcher = searchers[2]
searchers[2] = function(name)
	local loader, file = origLuaSearcher(name)
	if type(loader) == "function" then
		local info = debug.getinfo(loader, "S")
		local src = info and info.source
		if src and src:sub(1, 1) == "@" then
			local key = normKey(hot.abs(src:sub(2)))
			M.moduleFile[name] = key
			local set = M.fileModules[key]
			if not set then set = {}; M.fileModules[key] = set end
			set[name] = true
		end
	end
	return loader, file
end

local origRequire = require
local loadStack = {}
require = function(name)
	if type(name) ~= "string" then return origRequire(name) end
	local caller = loadStack[#loadStack]
	loadStack[#loadStack + 1] = name
	local ok, result = pcall(origRequire, name)
	loadStack[#loadStack] = nil
	if not ok then error(result, 0) end
	if caller and caller ~= name then
		local deps = M.dependents[name]
		if not deps then deps = {}; M.dependents[name] = deps end
		deps[caller] = true
	end
	return result
end

os.exit = function(code)
	if code == true then code = 0 end
	error(hot.exitMarker .. tostring(code or 0), 0)
end

local function acceptOwner(level)
	local info = debug.getinfo(level, "S")
	local src = info and info.source
	if src and src:sub(1, 1) == "@" then
		local key = normKey(hot.abs(src:sub(2)))
		if key ~= hot.entryKey then
			local names = M.fileModules[key]
			if names then
				for name in pairs(names) do return name end
			end
		end
	end
	return ENTRY_OWNER
end

local function accept(fn)
	if type(fn) ~= "function" then
		error("package.hot.accept expects a function, got " .. type(fn), 2)
	end
	local owner = acceptOwner(2)
	local list = M.accepts[owner]
	if not list then
		list = {}
		M.accepts[owner] = list
	end
	list[#list + 1] = fn
end

if hot.mode == "hot" then
	package.hot = { accept = accept, poll = hot.poll }
end

local function collect(names, out)
	for name in pairs(names) do
		if not out[name] then
			out[name] = true
			local deps = M.dependents[name]
			if deps then collect(deps, out) end
		end
	end
end

local function drop(name)
	package.loaded[name] = nil
	local key = M.moduleFile[name]
	if key then
		local set = M.fileModules[key]
		if set then
			set[name] = nil
			if next(set) == nil then M.fileModules[key] = nil end
		end
		M.moduleFile[name] = nil
	end
	M.dependents[name] = nil
	M.accepts[name] = nil
end

local function snapshotAccepts()
	local out = {}
	for _owner, list in pairs(M.accepts) do
		for i = 1, #list do out[#out + 1] = list[i] end
	end
	return out
end

local function queue(callbacks, names)
	for i = 1, #callbacks do
		local fn = callbacks[i]
		if not M.pendingCallbackSet[fn] then
			M.pendingCallbackSet[fn] = true
			M.pendingCallbacks[#M.pendingCallbacks + 1] = fn
		end
	end
	for i = 1, #names do
		local name = names[i]
		if not M.pendingNameSet[name] then
			M.pendingNameSet[name] = true
			M.pendingNames[#M.pendingNames + 1] = name
		end
	end
end

local function notify(callbacks, names)
	for i = 1, #names do
		local name = names[i]
		for j = 1, #callbacks do
			local ok, err = pcall(callbacks[j], name)
			if not ok then
				io.stderr:write("[lde --hot] package.hot.accept callback failed for '", name, "': ", tostring(err), "\n")
			end
		end
	end
end

function M.reload(changedKey)
	local names = M.fileModules[changedKey]
	if not names or next(names) == nil then return 0 end
	local out = {}
	collect(names, out)
	local list = {}
	for name in pairs(out) do list[#list + 1] = name end
	table.sort(list)
	local callbacks = snapshotAccepts()
	for i = 1, #list do drop(list[i]) end
	M.lastReloaded = list
	queue(callbacks, list)
	return #list
end

function M.flushAccepts(isApplied)
	local callbacks, names = M.pendingCallbacks, M.pendingNames
	if #names == 0 then return 0 end
	M.pendingCallbacks, M.pendingNames = {}, {}
	M.pendingCallbackSet, M.pendingNameSet = {}, {}
	if not isApplied then return 0 end
	notify(callbacks, names)
	return #names
end

function M.beginEntry()
	M.accepts[ENTRY_OWNER] = nil
end

function M.checkKey(absPath)
	local key = normKey(absPath)
	return key == hot.entryKey or M.fileModules[key] ~= nil
end

return M
]==]
