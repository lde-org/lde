---
title: Test Runner
order: 3
---

# Test Runner

Testing is essential. That's why most programming languages ship their own form of testing capabilities with their runtimes.

Rust has `cargo test`, Node recently even got `node:test`, Bun has `bun test`.

So why not Lua? That's why lde comes with a built-in test runner!

## lde test

This command is used to run a set of lua files you create inside of your /tests/ folder. You can nest them in folders however you like.

It will run all of the files in that folder using the [LDE runtime](/docs/features/runtime).

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

### Usage

Simply add the types to your package and use the built-in LuaCATs types for lde-test!

```
lde add lde-test --dev --git https://github.com/lde-org/lde
```
