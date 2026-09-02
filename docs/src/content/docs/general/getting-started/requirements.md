---
title: Requirements
order: 3
---

# Requirements

By default, `lde` tries to work out of the box for the majority of users. This is why it ships built-in git, curl, and archive support.

This, however, is different for compilation, via `lde compile`.

## Compilation

The way that `build.lua` scripts, and luarocks packages work in lde is by relying on a C compiler on your system to build native modules.

### Windows

It is difficult to set up a C compiler let alone a full GNU environment as is common with lua packages on Windows.

For this reason, lde automatically downloads and sets up a [clang-based toolchain](/docs/general/misc/windows-toolchain) on first use. It is ~30mB compressed, so it should not take too long to download.

### Linux

A compiler is not shipped out of the box. Install `clang` via your package manager:

```sh
apt install clang
dnf install clang
pacman -S clang
```

### MacOS

Clang ships with Xcode. Install it via `xcode-select --install`
