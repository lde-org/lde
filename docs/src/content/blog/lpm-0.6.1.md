---
title: Release v0.6.1
author: David Cruz
published: 2026-02-20
description: Adds lpm install and lpm uninstall for globally available tools, native C module support via LuaJIT exports, and C library bundling in compiled binaries.
---

> **NOTE**: This article was made before [the rebrand to lde](https://github.com/codebycruz/lpm/issues/73). Just replace `lpm` with `lde`.

> Upgrade to the latest version with `lpm upgrade`!

## `lpm install` and `lpm uninstall`

lpm now supports installing tools globally with `lpm install`, the equivalent of `cargo install`, `uv tool add`, `npm i -g`, or `luarocks install`.

It installs a package as a globally-available tool, so you can invoke it by name without needing to `lpm x` it with a full path every time.

```sh
lpm install --git https://github.com/user/my-tool
my-tool --help
```

`lpm uninstall` removes a previously installed tool.

## Native C module support

The `lpm` engine now supports native C modules (`.so` on Linux, `.dll` on Windows) by building lpm with LuaJIT's C module exports exposed.

> **Note:** Linux only for now, Windows is a little trickier since you can't export symbols from a binary directly.

## Native C modules in compiled binaries

Any `.so` or `.dll` files present in `target` are now preserved when running `lpm compile`, so native C libraries are bundled correctly into your self-contained executable (SEA) apps.

This works via storing their raw code into the binary, and then extracting them at startup to a temporary deterministic directory. Then, in the same way lua files are resolved with package.preload, the C modules are resolved too.
