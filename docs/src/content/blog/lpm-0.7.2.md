---
title: Release v0.7.2
author: David Cruz
published: 2026-03-24
description: Adds Windows ARM64 support, --help flag, lpm run for single files, new lpm-test assertions, and fixes for Windows upgrade permissions and UTF-8 output.
---

> Upgrade to the latest version with `lpm upgrade`!

## Windows ARM64 support

lpm now ships with a native Windows ARM64 build. It's included in the standard install script, so no extra steps needed:

```powershell
irm https://lualpm.com/install.ps1 | iex
```

## `--help` flag

You can now pass `--help` to get usage information, as an alternative to running `lpm` with no arguments:

```sh
lpm --help
```

## `lpm run` outside of a project

`lpm run` now accepts a file path directly, so you can run a Lua file without being inside an lpm project:

```sh
lpm run ./myscript.lua
```

## `--version` flag for install scripts

The install scripts now accept a `--version` flag to install a specific release:

```sh
# Linux
curl -fsSL https://lualpm.com/install | sh -s -- --version 0.7.2

# Windows
irm https://lualpm.com/install.ps1 | iex -Args --version, 0.7.2
```

## New `lpm-test` assertions

Several new assertion functions have been added to `lpm-test`:

```lua
test.truthy(value)
test.falsy(value)
test.includes(haystack, needle)
test.greater(a, b)
test.less(a, b)
test.greaterEqual(a, b)
test.lessEqual(a, b)
test.count(table) -- returns number of entries
```

## Bug fixes

- **Windows upgrade permissions** — fixed a permissions error when `lpm upgrade` tried to replace its own executable on Windows.
- **Windows UTF-8 output** — UTF-8 console output is now enabled on startup, fixing garbled characters in Windows terminals.

## Renamed field: `package` → `name`

The field used for package aliases in your project config has been renamed from `package` to `name`. Update your `lpm.json` if you're using this field.
