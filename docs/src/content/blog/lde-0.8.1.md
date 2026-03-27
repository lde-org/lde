---
title: Release v0.8.1
author: David Cruz
published: 2026-03-27
description: lpm is now lde. New domain, new name, backwards compatible — plus expanded LuaRocks support for make and cmake build types.
---

> Upgrade to the latest version with `lde upgrade`!

## lpm is now lde

The biggest change in this release is a full rebrand. `lpm` is now **lde**, and the project has moved to [lde.sh](https://lde.sh).

| Old | New |
|-----|-----|
| `lpm` | `lde` |
| `lpx` | `ldx` |
| `lpm.json` | `lde.json` |
| `lpm-lock.json` | `lde.lock` |
| `lualpm.com` | `lde.sh` |

**Backwards compatibility is maintained.** `lpm.json` files are still recognized and will continue to work — you should rename them to `lde.json` when you get the chance. The `"engine": "lpm"` field is still accepted, but `"lde"` is now the default.

Because this is a full rename, `lpm upgrade` won't migrate you to `lde` — you'll need to install it fresh. You can uninstall `lpm` with `rm -rf ~/.lpm`.


```sh
# Linux
curl -fsSL https://lde.sh/install | sh

# Windows
irm https://lde.sh/install.ps1 | iex
```

## Expanded LuaRocks support

### `make` build type

lde can now build rockspecs that use the `make` build type, which unlocks packages like `luasocket`:

```sh
lde add rocks:luasocket
```

![socket](/blog-assets/0.8.1/socket.gif)

### `cmake` build type

cmake-based rockspecs are now supported too, enabling packages like `luv`:

```sh
lde add rocks:luv
```

![luv](/blog-assets/0.8.1/luv.gif)

### CLI argument passthrough fix

`ldx` and `lde install` now correctly pass arguments through to the CLI being invoked.

### Faster manifest parsing

lde aims to be fast. LuaRocks manifest parsing is now lazy — previously lde would allocate and parse the entire manifest (~0.5s), now it pattern-matches directly to find the requested package, dropping lookup time to virtually zero. The manifest is also cached on disk for 24 hours, so subsequent installs skip the download entirely — both for speed and to avoid hammering the LuaRocks servers.

### lde update supports LuaRocks packages

`lde update` now works for LuaRocks dependencies alongside native lde packages.

## lde outdated

New command to check which of your dependencies have newer versions available:

```sh
lde outdated
```

## Install progress display

lde now shows progress while installing and building packages, so you're not left wondering what's happening during long installs.

## lde -e

You can now evaluate a Lua expression directly from the command line:

```sh
lde -e "print('hello')"
```
