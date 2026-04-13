---
title: Release v0.6.3
author: David Cruz
published: 2026-03-04
description: Introduces lpm --setup for one-step environment configuration, the lpx convenience wrapper, and simplified install scripts that delegate setup to lpm itself.
---

> Upgrade to the latest version with `lpm upgrade`!

## `lpm --setup`

Running `lpm --setup` now configures your environment in one step:

- Adds `~/.lpm` and `~/.lpm/tools` to your `PATH` (via your shell rc file on Unix, or the user registry on Windows)
- Installs an `lpx` convenience script alongside the `lpm` binary

## `lpx`

`lpx` is a thin wrapper that forwards all arguments to `lpm x`, so you can run one-off tools without typing the full command:

```sh
lpx my-tool arg1 arg2
# equivalent to: lpm x my-tool arg1 arg2
```

## Simplified Installation

The install scripts (`install.sh` / `install.ps1`) now delegate all post-install configuration to `lpm --setup`, keeping them minimal.

## `lpm upgrade --nightly`

You can now upgrade to the latest nightly build directly:

```sh
lpm upgrade --nightly
```

This means you can test out the code from the absolute latest commits without waiting for a formal release. Note that nightly builds may be unstable, so use with caution.

## Bug fixes

- Fixed git dependency resolution in monorepos: when a git repository contains multiple `lpm.json` files, lpm now correctly picks the one whose `name` matches the requested dependency instead of returning the first match found.

## Developer tooling

- Fixed `luarc.json` so that LuaLS resolves `require` calls against the `target/` directory, fixing types not resolving if 'target' is gitignored (which it should be).
- Improved test output for workspaces with multiple packages.
