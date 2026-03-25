---
title: Release v0.7.1
author: David Cruz
published: 2026-03-15
description: Adds registry dependency support to lpm install and lpx, a --nightly flag for install scripts, and Aarch64 macOS support.
---

> Upgrade to the latest version with `lpm upgrade`!

## Registry dependencies in `lpm install` and `lpx`

`lpm install` and `lpx` / `lpm x` now support registry dependencies. You can run a package from the registry directly without adding it to a project first:

```sh
lpm install hood
lpx hood
```

Previously only git dependencies were supported in these commands.

## `--nightly` flag for install scripts

The install scripts now accept a `--nightly` flag to install the latest nightly build of lpm instead of the latest stable release:

```sh
# Linux
curl -fsSL https://lualpm.com/install | sh -s -- --nightly

# Windows
irm https://lualpm.com/install.ps1 | iex -Args --nightly
```

Nightly builds reflect the latest commits and may be unstable. Use `lpm upgrade` (without `--nightly`) to switch back to a stable release.

## macOS support

Aarch64 macOS is now officially supported and passes the full test suite. Intel macOS support is coming soon.

To install on Apple Silicon:

```sh
curl -fsSL https://lualpm.com/install | sh
```
