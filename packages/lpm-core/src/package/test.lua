local fs = require("fs")
local path = require("path")
local ffi = require("ffi")
local runtime = require("lpm-core.runtime")

---@class lpm.TestFileResult
---@field file string
---@field results lpm.test.Result[]
---@field error string?

---@class lpm.TestResults
---@field package lpm.Package
---@field files lpm.TestFileResult[]
---@field total number
---@field failures number
---@field skipped number
---@field error string?

local function getLuaPathsForPackage(package)
	local modulesDir = package:getModulesDir()

	local luaPath =
		path.join(modulesDir, "?.lua") .. ";"
		.. path.join(modulesDir, "?", "init.lua") .. ";"

	local luaCPath =
		ffi.os == "Linux" and path.join(modulesDir, "?.so") .. ";"
		or ffi.os == "Windows" and path.join(modulesDir, "?.dll") .. ";"
		or path.join(modulesDir, "?.dylib") .. ";"

	return luaPath, luaCPath
end

local lpmTest = require("lpm-test.test")

--- Runs all tests for this package.
---@param package lpm.Package
---@return lpm.TestResults
local function runTests(package)
	package:installDependencies()
	package:installDevDependencies()
	package:build()

	local testDir = package:getTestDir()
	if not fs.exists(testDir) then
		return {
			package = package,
			files = {},
			total = 0,
			failures = 0,
			error = "No tests directory found in package: " .. testDir
		}
	end

	local luaPath, luaCPath = getLuaPathsForPackage(package)

	---@type lpm.TestFileResult[]
	local files = {}
	local totalTests = 0
	local totalFailures = 0
	local totalSkipped = 0

	local testFiles = fs.scan(testDir, "**" .. path.separator .. "*.lua")
	for _, relativePath in ipairs(testFiles) do
		local testFile = path.join(testDir, relativePath)

		local testObj = lpmTest.new()

		local ok, err = runtime.executeFile(testFile, {
			packagePath = luaPath,
			packageCPath = luaCPath,
			preload = {
				["lpm-test"] = function() return testObj end
			}
		})

		if not ok then
			files[#files + 1] = {
				file = relativePath,
				results = {},
				error = err
			}
		else
			local results = testObj.run()
			local failCount = 0
			local skipCount = 0
			for _, r in ipairs(results) do
				if r.skipped then
					skipCount = skipCount + 1
				elseif not r.ok then
					failCount = failCount + 1
				end
			end

			totalTests = totalTests + #results - skipCount
			totalFailures = totalFailures + failCount
			totalSkipped = totalSkipped + skipCount

			files[#files + 1] = {
				file = relativePath,
				results = results
			}
		end
	end

	return {
		package = package,
		files = files,
		total = totalTests,
		failures = totalFailures,
		skipped = totalSkipped
	}
end

return runTests
