---
title: Test Api
order: 0
---

The `lde-test` framework provides a simple API for defining and running tests.

## Typings

To get the LuaCATs types for `lde-test`, add the lde-test package as a dev dependency to your package:

```sh
lde add --dev gh:lde-test@lde-org/lde
```

## Methods

### `test.it(expectation: string, fn: fun())`

This registers a test to be run with the given expectation and function.

```lua
test.it("writes a file", function()
    fs.write("tmp/test-output", "hello")
    test.truthy(fs.exists("tmp/test-output"))
end)
```
