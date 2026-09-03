---
title: Test Api
order: 0
---

The `lde-test` framework provides a minimal API for defining and running tests.

It ships with the lde runtime and is injected into every test file that `lde test` runs, so you get the framework by requiring `lde-test`:

```lua
local test = require("lde-test")
```

> [!NOTE]
> A test file only registers tests: once the file has been evaluated, `lde test` runs the suite automatically. See the [introduction](/docs/test-runner/getting-started/introduction) for how test files are discovered and run.

## Typings

To get the LuaCATs types for `lde-test`, add the lde-test package as a dev dependency to your package:

```sh
lde add --dev gh:lde-test@lde-org/lde
```

## Registering Tests

### `test.it(name: string, fn: fun())`

Registers a test with the given name and function. `fn` is executed when the suite runs; an assertion that fails throws out of it and marks the test as failed.

```lua
test.it("writes a file", function()
	fs.write("tmp/test-output", "hello")
	test.truthy(fs.exists("tmp/test-output"))
end)
```

### `test.skip(name: string, fn: fun()?)`

Registers a test that is reported as skipped and never executed. Use it for tests you know are broken or not yet implemented:

```lua
test.skip("not implemented yet")
```

### `test.skipIf(condition: boolean) -> fun(name: string, fn: fun())`

Returns a function that registers a test just like `test.it`, except the test is skipped when `condition` is truthy. Handy for gating tests on the platform or environment:

```lua
local isWindows = package.config:sub(1, 1) == "\\"

test.skipIf(isWindows)("unix-only behavior", function()
	-- ...
end)
```

## Hooks

### `test.afterEach(fn: fun())`

Registers `fn` to run after every executed test, whether it passed or failed. If it throws, the test it follows is reported as failed:

```lua
local scratch = {}

test.it("adds an entry", function()
	scratch.key = "value"
	test.equal(scratch.key, "value")
end)

test.afterEach(function()
	scratch = {}
end)
```

### `test.afterAll(fn: fun())`

Registers `fn` to run once, after all registered tests have run. Use it for teardown that should happen exactly once no matter how many tests ran:

```lua
test.afterAll(function()
	-- shared teardown
end)
```

## Assertions

Assertions throw when their check fails, which fails the test they run inside.

> [!NOTE]
> Every assertion takes an optional trailing context message (`msg`) that is appended to the failure output. `test.equal(1, 2, "must add up")` fails with `Expected 1 to equal 2 (must add up)`.

### `test.equal(a: any, b: any, msg?: string)`

Fails unless `a` equals `b`. Comparison follows Lua semantics: numbers and strings compare by value, tables by identity, so use `test.deepEqual` when you care about table contents.

```lua
test.equal(1 + 1, 2)
test.equal("foo", "foo")
```

### `test.notEqual(a: any, b: any, msg?: string)`

Fails when `a` equals `b`:

```lua
test.notEqual(1, 2)
```

### `test.truthy(value: any, msg?: string)`

Fails when `value` is `false` or `nil`:

```lua
test.truthy(fs.exists("src/init.lua"))
```

### `test.falsy(value: any, msg?: string)`

Fails when `value` is anything other than `false` or `nil`:

```lua
test.falsy(fs.exists("tmp/scratch"))
```

### `test.includes(haystack: string, needle: string, msg?: string)`

Fails when `needle` is not a substring of `haystack`. This is a plain substring search, so Lua patterns are not interpreted:

```lua
test.includes("hello world", "world")
```

### `test.greater(a: number, b: number, msg?: string)`

Fails unless `a` is greater than `b`:

```lua
test.greater(#items, 0)
```

### `test.less(a: number, b: number, msg?: string)`

Fails unless `a` is less than `b`:

```lua
test.less(processed, total)
```

### `test.greaterEqual(a: number, b: number, msg?: string)`

Fails unless `a` is greater than or equal to `b`:

```lua
test.greaterEqual(score, 100)
```

### `test.lessEqual(a: number, b: number, msg?: string)`

Fails unless `a` is less than or equal to `b`:

```lua
test.lessEqual(elapsed, timeout)
```

### `test.deepEqual(a: any, b: any, msg?: string)`

Recursively compares `a` to `b`. Fails on any difference: mismatched values at any depth, keys present in `a` but missing from `b`, type mismatches, or different metatables. Array order matters, since indices are compared as keys.

```lua
local got = { name = "alice", tags = { "admin" } }
test.deepEqual(got, { name = "alice", tags = { "admin" } })
```

### `test.match(actual: table, expected: table, msg?: string)`

Fails unless `actual` contains every key/value pair in `expected`. Values in `expected` are compared recursively, and extra keys in `actual` are fine:

```lua
local response = { status = 200, body = { ok = true, id = 42 } }
test.match(response, { status = 200 })
test.match(response, { body = { ok = true } })
```

### `test.errors(fn: fun(), expected?: any, msg?: string)`

Fails unless `fn` throws. With `expected`, the thrown error must match it: string errors are compared without the `path:line:` prefix that `pcall` adds, and non-string errors are compared by identity.

```lua
test.errors(function() error("boom") end)
test.errors(function() error("boom") end, "boom")

local err = { code = 42 }
test.errors(function() error(err) end, err)
```

## Helpers

### `test.count(tbl: table) -> number`

Returns the number of keys in `tbl`, counting array and hash entries alike:

```lua
test.equal(test.count({ "a", "b", "c" }), 3)
test.equal(test.count({ x = 1, y = 2 }), 2)
```
