---@alias lpm.test.Result
--- | { name: string, ok: true }
--- | { name: string, ok: false, error: string }

---@class lpm.test
---@field it fun(name: string, fn: fun())
---@field run fun(): lpm.test.Result[]
---@field equal fun(a: any, b: any)
---@field notEqual fun(a: any, b: any)
---@field truthy fun(value: any)
---@field falsy fun(value: any)
---@field includes fun(haystack: string, needle: string)
---@field greater fun(a: number, b: number)
---@field less fun(a: number, b: number)
---@field greaterEqual fun(a: number, b: number)
---@field lessEqual fun(a: number, b: number)
---@field count fun(table: table): number
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

--- Creates a fresh, independent test instance.
---@return lpm.test
function M.new()
	local callbacks = {}

	local instance = {}

	function instance.it(name, fn)
		table.insert(callbacks, { name = name, callback = fn })
	end

	function instance.run()
		---@type lpm.test.Result[]
		local results = {}

		for _, callback in ipairs(callbacks) do
			local ok, err = pcall(callback.callback)
			table.insert(results, { name = callback.name, ok = ok, error = err })
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

	return instance
end

return M
