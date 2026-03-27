---
title: Release v0.6.2
author: David Cruz
published: 2026-02-21
description: Adds the bin field in lpm.json for custom entrypoints, bytecode output for lpm bundle, and several bug fixes around stdout/stderr handling and working directory behavior.
---

> **NOTE**: This article was made before [the rebrand to lde](https://github.com/codebycruz/lpm/issues/73). Just replace `lpm` with `lde`.

> Upgrade to the latest version with `lpm upgrade`!

## `bin` field in `lpm.json`

You can now set a `bin` field in your `lpm.json` to declare the entrypoint used by `lpm run` and `lpm x`. This is useful for packages that expose both a library and a CLI entrypoint as separate files.

```json
{
	"name": "my-tool",
	"bin": "cli.lua"
}
```

## `lpm bundle --bytecode`

`lpm bundle --bytecode` now compiles the entire output file to LuaJIT bytecode, producing a bytecode blob instead of a Lua source file. This reduces file size and improves startup time.

Previously, it only stored each individual file that was dynamically loaded as bytecode.

## Bug fixes

- Fixed `lpm run` with an external engine (e.g. `"engine": "lua"` in `lpm.json`) not inheriting stdout/stderr — output was silently swallowed instead of being shown to the user.
- Fixed `lpm run` with the `lpm` engine not setting the working directory to the project's directory when running build scripts.
- Fixed `lpm x` running tools with the working directory set to the package location instead of where the user invoked the command.
