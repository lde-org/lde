---
title: Release v0.8.1
author: David Cruz
published: 2026-03-27
description: lpm is now lde. New domain, repository and name while remaining backwards compatible. Expanded LuaRocks support.
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

**Backwards compatibility is maintained.**

`lpm.json` files are still recognized and will continue to work. (You should rename them to `lde.json` when you get the chance though).

Because of the nature of the change and repository shift, `lpm upgrade` won't be able to migrate you to lde successfully. So you'll need to install from scratch, unfortunately.

The good news is uninstalling lpm is as easy as `rm -rf ~/.lpm`.

```sh
# Linux
curl -fsSL https://lde.sh/install | sh

# Windows
irm https://lde.sh/install.ps1 | iex
```

Run the typical install script above to reinstall it. Or download it manually again. That works too.

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

lde should be fast. It already cached the LuaRocks manifest being fetched and parsed, however, it would parse the entire manifest. Now it lazily scans for only the dependencies you need and caches the raw contents of the manifest leading to 100x faster parse times on cold starts (eliminating what could be ~0.5s).

The manifest is also cached on disk for 24 hours, so subsequent installs skip the download entirely for speed and to avoid hammering the LuaRocks servers.

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

Useful for quick tests and especially for LLMs to test code in the context of a package.
