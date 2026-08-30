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

The good news is, on windows, since it is difficult to set up a C compiler (especially one that behaves with unix based builds), [lde automatically downloads and sets up a clang-based toolchain on first use](/docs/general/misc/windows-mingw). It is ~30mB compressed, so it should not take too long to download.

### Linux

For linux, a compiler is not shipped out of the box. You'll want to install `clang` via your favorite package manager:

```
apt install clang
dnf install clang
pacman -S clang
```

### MacOS

For MacOS, clang ships with Xcode Command Line Tools. You can install it via `xcode-select --install`.

### Using Another Compiler

To use a specific compiler (for example, with cross compilation), set the `SEA_CC` environment variable:

```sh
SEA_CC=clang lde compile
```

This is only really needed for [cross compiles](/docs/bundler/features/cross-compilation).
