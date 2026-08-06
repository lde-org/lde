---@meta

---@alias lde.test.Result
--- | { name: string, ok: true }
--- | { name: string, ok: false, error: string }
--- | { name: string, ok: true, skipped: true }

---@class lde.TestReporter
---@field onFileStart? fun(file: string)
---@field onFileDone?  fun(file: string)
---@field onStart?     fun(name: string): any
---@field onPass?      fun(name: string, handle: any)
---@field onFail?      fun(name: string, err: string, handle: any, file?: string)
---@field onSkip?      fun(name: string)

---@class lde.test
---@field it fun(name: string, fn: fun())
---@field skip fun(name: string, fn: fun()?)
---@field skipIf fun(condition: boolean): fun(name: string, fn: fun())
---@field afterEach fun(fn: fun())
---@field afterAll fun(fn: fun())
---@field run fun(reporter?: lde.TestReporter): lde.test.Result[]
---@field equal fun(a: any, b: any)
---@field notEqual fun(a: any, b: any)
---@field truthy fun(value: any)
---@field falsy fun(value: any)
---@field includes fun(haystack: string, needle: string)
---@field greater fun(a: number, b: number)
---@field less fun(a: number, b: number)
---@field greaterEqual fun(a: number, b: number)
---@field lessEqual fun(a: number, b: number)
---@field count fun(tbl: table): number
---@field deepEqual fun(a: any, b: any)
---@field match fun(actual: table, expected: table)

---@return lde.test
local function create() end

return create()
