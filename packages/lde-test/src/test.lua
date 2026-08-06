--- Host side of the lde-test framework.
---
--- The framework itself runs inside each test file's guest state, so its
--- implementation is embedded below as a string — the single source of
--- truth for how lde-test behaves. The host side only crosses primitives
--- (test names, booleans, error strings) across the state boundary: the
--- reporter is adapted here into primitive-only host callbacks, which are
--- passed into the guest as varargs when the framework is injected.

--- The guest-side framework. Receives the host reporter callbacks as varargs
--- (primitives only), exposes itself via package.preload so require("lde-test")
--- and require("lpm-test") resolve to a fresh instance, and returns the suite
--- runner the host invokes once the test file has been evaluated.
---
--- The assertion and runner logic stays guest-side: tests register guest
--- closures and compare guest tables, and neither can cross to the host.
local SOURCE = [==[
	local onResult, onStart, onPass, onFail, onSkip = ...

	local M = {}

	local function equal(a, b)
		if a ~= b then error("Expected " .. tostring(a) .. " to equal " .. tostring(b), 2) end
	end

	local function notEqual(a, b)
		if a == b then error("Expected " .. tostring(a) .. " not to equal " .. tostring(b), 2) end
	end

	local function truthy(v)
		if not v then error("Expected value to be truthy, got " .. tostring(v), 2) end
	end

	local function falsy(v)
		if v then error("Expected value to be falsy, got " .. tostring(v), 2) end
	end

	local function includes(haystack, needle)
		if not string.find(haystack, needle, 1, true) then
			error("Expected string to include '" .. needle .. "'", 2)
		end
	end

	local function greater(a, b)
		if not (a > b) then
			error("Expected " .. tostring(a) .. " to be greater than " .. tostring(b), 2)
		end
	end

	local function less(a, b)
		if not (a < b) then
			error("Expected " .. tostring(a) .. " to be less than " .. tostring(b), 2)
		end
	end

	local function greaterEqual(a, b)
		if not (a >= b) then
			error("Expected " .. tostring(a) .. " to be greater than or equal to " .. tostring(b), 2)
		end
	end

	local function lessEqual(a, b)
		if not (a <= b) then
			error("Expected " .. tostring(a) .. " to be less than or equal to " .. tostring(b), 2)
		end
	end

	local function count(tbl)
		local n = 0
		for _ in pairs(tbl) do n = n + 1 end
		return n
	end

	local function deepEqualInner(a, b, path)
		if a == b then return end
		if type(a) ~= type(b) then
			error("Expected " .. path .. " to be " .. type(b) .. ", got " .. type(a), 0)
		end
		if type(a) ~= "table" then
			error("Expected " .. path .. " to equal " .. tostring(b) .. ", got " .. tostring(a), 0)
		end
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

	local function deepEqual(a, b)
		local ok, err = pcall(deepEqualInner, a, b, "<root>")
		if not ok then error(err, 2) end
	end

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

	local function match(actual, expected)
		if type(actual) ~= "table" then
			error("Expected a table, got " .. type(actual), 2)
		end
		local ok, err = pcall(matchInner, actual, expected, "<root>")
		if not ok then error(err, 2) end
	end

	function M.new()
		local callbacks, afterEachFns, afterAllFns = {}, {}, {}

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

		function instance.afterEach(fn)
			table.insert(afterEachFns, fn)
		end

		function instance.afterAll(fn)
			table.insert(afterAllFns, fn)
		end

		function instance.run(reporter)
			local results = {}
			reporter = reporter or {}

			for _, callback in ipairs(callbacks) do
				if callback.skipped then
					if reporter.onSkip then reporter.onSkip(callback.name) end
					table.insert(results, { name = callback.name, ok = true, skipped = true })
				else
					local handle = reporter.onStart and reporter.onStart(callback.name)
					local ok, err = pcall(callback.callback)
					for _, fn in ipairs(afterEachFns) do
						local aok, aerr = pcall(fn)
						if not aok then ok, err = false, aerr end
					end
					if ok and reporter.onPass then
						reporter.onPass(callback.name, handle)
					elseif not ok and reporter.onFail then
						reporter.onFail(callback.name, err, handle)
					end
					table.insert(results, { name = callback.name, ok = ok, error = err })
				end
			end

			for i, fn in ipairs(afterAllFns) do
				local ok, err = pcall(fn)
				if not ok then
					table.insert(results, { name = "afterAll #" .. i, ok = false, error = err })
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

	local instance = M.new()
	package.preload["lde-test"] = function() return instance end
	package.preload["lpm-test"] = function() return instance end

	return function()
		local reporter = {}
		if onStart then reporter.onStart = function(name)         onStart(name)        end end
		if onPass  then reporter.onPass  = function(name, _)      onPass(name)         end end
		if onFail  then reporter.onFail  = function(name, err, _) onFail(name, err)    end end
		if onSkip  then reporter.onSkip  = function(name)         onSkip(name)         end end
		for _, r in ipairs(instance.run(reporter)) do
			onResult(r.name, r.ok == true, r.skipped == true, r.error or "")
		end
	end
]==]

---@class lde.testHost
---@field file string? # test file path, forwarded to reporter.onFail for error snippets
---@field onResult fun(name: string, ok: boolean, skipped: boolean, err: string)

--- Inject lde-test into a guest state.
---
--- Sets up package.preload["lde-test"] / ["lpm-test"] inside the guest and
--- returns the suite runner: call it once the test file source has been
--- evaluated (state:eval). The reporter is adapted to primitive-only host
--- callbacks — no compound values cross the state boundary.
---
---@param state    lua.State
---@param reporter lde.TestReporter?
---@param host     lde.testHost
---@return fun() runSuite
local function setup(state, reporter, host)
	-- Handles (e.g. progress spinners) live entirely host-side: onStart
	-- stores one per test name, onPass/onFail retrieve it by name.
	local handles = {}

	local onStart = reporter and reporter.onStart and function(name)
		handles[name] = reporter.onStart(name)
		-- no return: a handle cannot cross back into the guest
	end or nil
	local onPass = reporter and reporter.onPass and function(name)
		reporter.onPass(name, handles[name])
		handles[name] = nil
	end or nil
	local onFail = reporter and reporter.onFail and function(name, err)
		reporter.onFail(name, err, handles[name], host.file)
		handles[name] = nil
	end or nil
	local onSkip = reporter and reporter.onSkip and function(name)
		reporter.onSkip(name)
	end or nil

	local runSuite = state:load(SOURCE, "@lde-test.test"):eval(host.onResult, onStart, onPass, onFail, onSkip)
	---@cast runSuite fun()
	return runSuite
end

return { setup = setup }
