---
title: Requirements
order: 1
---

# Requirements

Both `lde bundle` and `lde compile` produce output tied to the LDE runtime, which is built on LuaJIT. The output is not intended to be used with standard Lua or other runtimes.

## Bundling

`lde bundle` works out of the box with no extra dependencies. The resulting `.lua` file runs under the LDE runtime (`lde run`) or any LuaJIT build.

The `--bytecode` flag compiles modules to LuaJIT bytecode. The output is only compatible with the same LuaJIT version LDE uses. It will not run on Lua 5.x or a different LuaJIT build.

## Compiling

`lde compile` requires a C compiler. lde prefers **clang** — it is what makes cross-compilation possible — and falls back to `gcc` for native builds when no clang is available:

- **Windows**: lde automatically downloads and sets up a clang-based toolchain on first use. No manual setup is needed. See [Windows C Compilation](/docs/general/features/windows-mingw) for details.
- **Linux**: install `clang` via your package manager (e.g., `apt install clang`, `dnf install clang`). `gcc` also works for native builds.
- **macOS**: clang ships with Xcode Command Line Tools. Run `xcode-select --install` if not already installed.

To use a specific compiler (for example a custom cross toolchain), set the `SEA_CC` environment variable:

```sh
SEA_CC=clang lde compile
```

`SEA_CC` is only needed for fringe setups — normal compiles, including cross-compiles, resolve clang automatically.

The resulting binary is fully self-contained and requires no Lua or LDE installation to run.
