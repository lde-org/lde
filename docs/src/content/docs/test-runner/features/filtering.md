---
title: Filtering
order: 2
---

Filtering tests is useful to restrict running tests to whatever is relevant to your current changes.

That is why lde allows you to filter with glob semantics for file paths.

## Single Filter

You can either pass a glob:

```sh
lde test "*auth*"
```

> [!WARNING]
> These match *test file names*, not test names provided to `test.it`

Or a specific file path:

```sh
lde test "./tests/unit/auth.test.lua"
```

## Multiple Filters

Multiple filters combine with OR semantics. A file is run if it matches *any* of them:

```sh
lde test "*auth*" "unit/*"
```

```sh
lde test ./tests/unit/auth.test.lua
lde test "./tests/unit/*"
```

> [!NOTE]
> If no files match your filters, the package is skipped silently in multi-package runs, or FAILS for a single package.
