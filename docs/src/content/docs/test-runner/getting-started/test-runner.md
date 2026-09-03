---
title: Test Runner
order: 0
---

Testing is essential. That's why most programming languages ship their own form of testing capabilities with their runtimes.

Rust has `cargo test`, Node recently even got `node:test`, Bun has `bun test`.

So why not Lua? That's why lde comes with a built-in test runner!

## lde test

This command is used to run a set of lua files you create inside of your `/tests/` folder. You can nest them in folders however you like.

It will run all files matching `*.test.lua` in that folder using the [LDE runtime](/docs/runtime/getting-started/runtime).

But just running files isn't traditionally enough. Usually you write more than a single test per file.

This is why lde ships the minimal testing library, [`lde-test`](#`lde-test`).

### Filtering Tests

You can pass glob patterns to `lde test` to run only a subset of your test files:

```sh
# Run only test files whose name contains "auth"
lde test "*auth*"

# Run only test files inside the unit/ directory
lde test "unit/*"
```

Multiple filters combine with OR semantics — a file is run if it matches *any* of them:

```sh
lde test "*auth*" "unit/*"
```

You can also target a specific file by path using `./` or `../` prefixes:

```sh
# Run a specific test file by relative path
lde test ./tests/unit/auth.test.lua
```

When passing a path, glob characters like `*` still work inside the resolved path:

```sh
# Run all test files inside the unit/ directory via path
lde test "./tests/unit/*"
```

If no files match your filters, the package is skipped silently (or shows "No files matched" in multi-package runs).

### Watch Mode

Pass `--watch` to re-run your tests automatically whenever a source or test file changes:

```sh
lde test --watch
```

Filters combine with watch mode — only matching files are re-run:

```sh
lde test --watch "unit/*"
```

The runner watches `src/` and `tests/`, and also picks up edits to `lde.json` and `build.lua`, so dependency or build-script changes trigger a re-run too. It works from a package directory or from a workspace root with multiple packages.

### Coverage

Pass `--coverage` to measure how much of your package's source your tests exercise:

```sh
lde test --coverage
```

The runner instruments the package's own modules (`src/`) with a line hook and prints a per-file report — executed lines, total executable lines, and a percentage — followed by a suite-wide total. Only files under the package's `src/` are measured; dependencies and the test framework itself are excluded. Blank and comment-only lines don't count as executable.

```sh
lde test --coverage "unit/*"
```

Coverage works with file filters and multi-package runs (each package gets its own report). Because line hooks disable the JIT, coverage runs are slower than normal test runs. Coverage is not supported for rockspec-based packages that use an external runner (busted).

### Coverage JSON

Pass `--json` to write the same report as machine-readable JSON for tooling and CI:

```sh
lde test --coverage --json coverage.json
```

`--json` implies `--coverage`, and a bare `--json` defaults to `coverage.json`. The file follows `schemas/lde.coverage.schema.json` and contains the combined totals plus one entry per package — each with its per-file rows (`executable`, `covered`, `percent`) sorted worst-first, so the least-tested modules come first. In a multi-package run all packages land in a single file, making it easy to diff coverage between commits or gate a CI step on a minimum percentage.

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

```sh
lde add lde-test --dev --git https://github.com/lde-org/lde
```
