---
title: Windows Toolchain
order: 4
---

# Windows Toolchain

On Windows, compiling programs with `lde compile` and installing C-based LuaRocks packages (like `luasocket`) requires a C compiler. lde handles this for you automatically.

## Automatic clang setup

If no compiler is found on your `PATH`, lde downloads and sets up a full toolchain for you.

> [!NOTE]
> The download is a highly compressed ~30mB .7z archive that you can [inspect here](https://github.com/lde-org/toolchain-dist)

It consists of [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) and [busybox](https://busybox.net/), and is installed into `~/.lde/mingw`

This is a one-time setup that happens on first use. After that, lde reuses the cached toolchain for every subsequent build.

## Toolchain

The toolchain is not just clang. It most notably contains `clang`, `make` and an install of [busybox](https://busybox.net) for a unix shell.
