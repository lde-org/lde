---
title: Test Runner
order: 1
---

# Test Runner

Testing is essential. That's why most programming languages ship their own form of testing capabilities with their runtimes.

Rust has `cargo test`, Node recently even got `node:test`, Bun has `bun test`.

So why not Lua? That's why lde comes with a built-in test runner!

## lde test

This command is used to run a set of lua files you create inside of your `/tests/` folder. You can nest them in folders however you like.

It will run all files matching `*.test.lua` in that folder using the [LDE runtime](/docs/runtime/getting-started/runtime).

But just running files isn't traditionally enough. Usually you write more than a single test per file.

This is why lde ships the minimal testing library, [`lde-test`](#`lde-test`).

## lde-test

This is a minimal testing library that comes bundled with lde. You can require it in your test files and use its simple API to write tests.

```lua
local test = require("lde-test")

test.it("should add numbers correctly", function()
	test.equal(1 + 1, 2)
end)

test.it("should handle tables", function()
	local t = {1, 2, 3}
	test.notEqual(#t, 4)
end)
```

### Teardown

Use `afterEach` to run cleanup after every test, and `afterAll` to run cleanup once after all tests finish.

```lua
local test = require("lde-test")
local fs = require("fs")

test.afterEach(function()
	fs.remove("tmp/test-output")
end)

test.afterAll(function()
	fs.remove("tmp")
end)

test.it("writes a file", function()
	fs.write("tmp/test-output", "hello")
	test.truthy(fs.exists("tmp/test-output"))
end)
```

If a teardown function throws, it's treated as a test failure. `afterEach` errors fail the associated test, and `afterAll` errors appear as a separate failure entry.

### Usage

Simply add the types to your package and use the built-in LuaCATs types for lde-test!

```
lde add lde-test --dev --git https://github.com/lde-org/lde
```
