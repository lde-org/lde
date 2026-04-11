---
title: Release v0.6.0
author: David Cruz
published: 2026-02-18
description: Introduces lpm-test, a built-in test runner with test suites and assertions, along with lpm bundle, lpm update and format preservation for lpm add and lpm remove.
---

> **NOTE**: This article was made before [the rebrand to lde](https://github.com/lde-org/lde/issues/73). Just replace `lpm` with `lde`.

> Upgrade to the latest version with `lpm upgrade`!

## Built-in test runner

Now lpm ships with a built-in test runner, `lpm-test`.

LPM has had `lpm test` for a while, but it just ran the lua files, so writing tests would involve separating into individual files for each assertion, which isn't ideal.

You can now use `lpm-test` which is provided by the lpm runtime to write tests in a more traditional way, with test suites and assertions.

```lua
local test = require('lpm-test')

test.it('should add numbers correctly', function()
	test.equal(1 + 1, 2)
end)

test.it('should handle tables', function()
	local t = {1, 2, 3}
	test.equal(#t, 3)
end)
```

You can read more about it on its dedicated docs page: [Test Runner](/docs/test-runner/getting-started/test-runner).

## `lpm_modules` renamed to `target`

The overly-verbose name following the convention of `node_modules` has been renamed to `target` for simplicity.

You may have to edit your `.gitignore` to ignore this new folder.

## `lpm bundle`

LPM now supports bundling your project into a single lua file, which is useful for distribution.

This can be done with the `lpm bundle` command, which will create a file `<projectname>.lua`.

This is useful as an alternative to `lpm compile` when you don't need a native executable.

## `lpm update`

This updates your unpinned git dependencies by pulling the latest changes from their respective repositories.

## `lpm add` and `lpm remove` preserve formatting

Previously, the json parser/stringifier used by `lpm add` and `lpm remove` would reformat the `lpm.json` file into a terse format without preserving field ordering. It'd pretty much nuke it.

Now, the JSON library has been replaced with one that preserves ordering and pretty prints nicely.

## Refactors

- Added a test suite and regression harness for lpm based on `lpm-test`.

## Bug fixes

- Fixed internal issues causing lpm compile to generate files that weren't executable (needed chmod +x)

- Fixed windows build up and got test harness passing on it.
