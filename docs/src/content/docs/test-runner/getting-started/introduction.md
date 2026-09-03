---
title: Test Runner
order: 0
---

One of the most important parts of modern day software development is testing your projects.

This is why lde ships with its own built-in test runner.

## `lde test`

This command runs all files matching `./tests/**/*.test.lua`.

> [!TIP]
> It also supports files written in teal (`*.tl`) and moonscript (`*.moon`).

But just running files isn't enough. You write more than a single test per file.

**This is why lde ships a minimal [testing framework](/docs/test-runner/api/test)**

### Monorepos

This command can also be run outside of a project directory, in which case it will search for nested packages to run tests of.

### Filtering

You can any amount of space delimited globs to `lde test` to run only a subset of your test files:

```sh
lde test "*auth*"
lde test "unit/*" "foo/bar/*"
lde test ./a/file/path/*
```

You can find the full specification here: [filtering](/docs/test-runner/features/filtering)

### Watch Mode

Pass `--watch` to re-run your tests automatically whenever a source or test file changes:

```sh
lde test --watch
```

It will also re-run when `lde.json` or `build.lua` changes.

### Coverage

Pass `--coverage` to measure how much of your package's source your tests exercise:

```sh
lde test --coverage
```

You can read more about coverage here: [Coverage](/docs/test-runner/features/coverage).

## `lde-test`

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

The full api is [documented here](/docs/test-runner/api/test)
