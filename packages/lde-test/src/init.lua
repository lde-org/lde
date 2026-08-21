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

--- Every assertion takes an optional trailing context message, appended to
--- the failure output.
---@class lde.test
---@field it fun(name: string, fn: fun())
---@field skip fun(name: string, fn: fun()?)
---@field skipIf fun(condition: boolean): fun(name: string, fn: fun())
---@field afterEach fun(fn: fun())
---@field afterAll fun(fn: fun())
---@field run fun(reporter?: lde.TestReporter): lde.test.Result[]
---@field equal fun(a: any, b: any, msg?: string)
---@field notEqual fun(a: any, b: any, msg?: string)
---@field truthy fun(value: any, msg?: string)
---@field falsy fun(value: any, msg?: string)
---@field includes fun(haystack: string, needle: string, msg?: string)
---@field greater fun(a: number, b: number, msg?: string)
---@field less fun(a: number, b: number, msg?: string)
---@field greaterEqual fun(a: number, b: number, msg?: string)
---@field lessEqual fun(a: number, b: number, msg?: string)
---@field count fun(tbl: table): number
---@field deepEqual fun(a: any, b: any, msg?: string)
---@field match fun(actual: table, expected: table, msg?: string)
---@field errors fun(fn: fun(), expected?: any, msg?: string) # fn must throw; with expected, the error must match it

---@return lde.test
local function create() end

return create()
