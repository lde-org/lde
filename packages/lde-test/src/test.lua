---@alias lde.test.Result
--- | { name: string, ok: true }
--- | { name: string, ok: false, error: string }
--- | { name: string, ok: true, skipped: true }

---@class lde.test
---@field it fun(name: string, fn: fun())
---@field skip fun(name: string, fn: fun()?)
---@field skipIf fun(condition: boolean): fun(name: string, fn: fun())
---@field run fun(): lde.test.Result[]
---@field equal fun(a: any, b: any)
---@field notEqual fun(a: any, b: any)
---@field truthy fun(value: any)
---@field falsy fun(value: any)
---@field includes fun(haystack: string, needle: string)
---@field greater fun(a: number, b: number)
---@field less fun(a: number, b: number)
---@field greaterEqual fun(a: number, b: number)
---@field lessEqual fun(a: number, b: number)
---@field deepEqual fun(a: any, b: any)
---@field match fun(actual: table, expected: table)
local M = {}

---@generic T
---@param a T
---@param b T
local function equal(a, b)
	if a ~= b then
		error("Expected " .. tostring(a) .. " to equal " .. tostring(b), 2)
	end
end

---@generic T
---@param a T
---@param b T
local function notEqual(a, b)
	if a == b then
		error("Expected " .. tostring(a) .. " not to equal " .. tostring(b), 2)
	end
end

---Asserts that a value is truthy
---@param value any
local function truthy(value)
	if not value then
		error("Expected value to be truthy, got " .. tostring(value), 2)
	end
end

---Asserts that a value is falsy
---@param value any
local function falsy(value)
	if value then
		error("Expected value to be falsy, got " .. tostring(value), 2)
	end
end

---Asserts that a string includes a substring
---@param haystack string
---@param needle string
local function includes(haystack, needle)
	if string.find(haystack, needle, 1, true) == nil then
		error("Expected string to include '" .. needle .. "'", 2)
	end
end

---Asserts that a is greater than b
---@param a number
---@param b number
local function greater(a, b)
	if not (a > b) then
		error("Expected " .. tostring(a) .. " to be greater than " .. tostring(b), 2)
	end
end

---Asserts that a is less than b
---@param a number
---@param b number
local function less(a, b)
	if not (a < b) then
		error("Expected " .. tostring(a) .. " to be less than " .. tostring(b), 2)
	end
end

---Asserts that a is greater than or equal to b
---@param a number
---@param b number
local function greaterEqual(a, b)
	if not (a >= b) then
		error("Expected " .. tostring(a) .. " to be greater than or equal to " .. tostring(b), 2)
	end
end

---Asserts that a is less than or equal to b
---@param a number
---@param b number
local function lessEqual(a, b)
	if not (a <= b) then
		error("Expected " .. tostring(a) .. " to be less than or equal to " .. tostring(b), 2)
	end
end

---Returns the number of items in a table (counted via pairs)
---@param tbl table
---@return number
local function count(tbl)
	local n = 0
	for _ in pairs(tbl) do n = n + 1 end
	return n
end

---@param a any
---@param b any
---@param path string
local function deepEqualInner(a, b, path)
	if a == b then return end
	if type(a) ~= type(b) then
		error("Expected " .. path .. " to be " .. type(b) .. ", got " .. type(a), 0)
	end
	if type(a) ~= "table" then
		error("Expected " .. path .. " to equal " .. tostring(b) .. ", got " .. tostring(a), 0)
	end
	-- compare metatables
	if getmetatable(a) ~= getmetatable(b) then
		error("Expected " .. path .. " metatables to match", 0)
	end
	for k, v in pairs(b) do
		deepEqualInner(a[k], v, path .. "." .. tostring(k))
	end
	for k in pairs(a) do
		if b[k] == nil then
			error("Unexpected key " .. path .. "." .. tostring(k), 0)
		end
	end
end

---Recursively asserts deep equality including metatables
---@param a any
---@param b any
local function deepEqual(a, b)
	local ok, err = pcall(deepEqualInner, a, b, "<root>")
	if not ok then error(err, 2) end
end

---@param actual table
---@param expected table
---@param path string
local function matchInner(actual, expected, path)
	for k, v in pairs(expected) do
		local ap = path .. "." .. tostring(k)
		if type(v) == "table" and type(actual[k]) == "table" then
			matchInner(actual[k], v, ap)
		else
			if actual[k] ~= v then
				error("Expected " .. ap .. " to equal " .. tostring(v) .. ", got " .. tostring(actual[k]), 0)
			end
		end
	end
end

---Asserts that actual contains all keys/values in expected (like jest's toMatchObject)
---@param actual table
---@param expected table
local function match(actual, expected)
	if type(actual) ~= "table" then
		error("Expected a table, got " .. type(actual), 2)
	end
	local ok, err = pcall(matchInner, actual, expected, "<root>")
	if not ok then error(err, 2) end
end

--- Creates a fresh, independent test instance.
---@return lde.test
function M.new()
	local callbacks = {}

	local instance = {}

	function instance.it(name, fn)
		table.insert(callbacks, { name = name, callback = fn })
	end

	function instance.skip(name, _fn)
		table.insert(callbacks, { name = name, skipped = true })
	end

	function instance.skipIf(condition)
		return function(name, fn)
			table.insert(callbacks, condition
				and { name = name, skipped = true }
				or { name = name, callback = fn })
		end
	end

	function instance.run()
		---@type lde.test.Result[]
		local results = {}

		for _, callback in ipairs(callbacks) do
			if callback.skipped then
				table.insert(results, { name = callback.name, ok = true, skipped = true })
			else
				local ok, err = pcall(callback.callback)
				table.insert(results, { name = callback.name, ok = ok, error = err })
			end
		end

		return results
	end

	instance.equal = equal
	instance.notEqual = notEqual
	instance.truthy = truthy
	instance.falsy = falsy
	instance.includes = includes
	instance.greater = greater
	instance.less = less
	instance.greaterEqual = greaterEqual
	instance.lessEqual = lessEqual
	instance.count = count
	instance.deepEqual = deepEqual
	instance.match = match

	return instance
end

return M
