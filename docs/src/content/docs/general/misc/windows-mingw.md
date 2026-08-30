---
title: Windows C Compilation
order: 4
---

# Windows C Compilation

On Windows, compiling programs with `lde compile` and installing C-based LuaRocks packages (like `luasocket`) requires a C compiler. lde handles this for you automatically.

## Automatic MinGW setup

If no compiler is found on your `PATH`, lde downloads and sets up [MinGW](https://www.mingw-w64.org/) (a GCC-based toolchain) into `~/.lde/mingw`. This is a one-time setup that happens on first use. After that, lde reuses the cached toolchain for every subsequent build.

The setup takes about a minute the first time. Once done, both `lde compile` and LuaRocks C packages work without any manual configuration.

## Using a different compiler

To use a specific compiler, set the `SEA_CC` environment variable before running lde:

```powershell
$env:SEA_CC = "clang"
lde compile
```
