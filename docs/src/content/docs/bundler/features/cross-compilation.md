---
title: Cross Compilation
order: 4
---

# Cross Compilation

You can cross compile your lde package to other platforms by specifying the `--target` flag when running `lde compile`.

This is desirable when you don't care about running the binary and want fast builds for continuous deployment release builds.

> [!WARNING]
> Support for cross compilation is **best effort** and **experimental**.

## Valid Targets

- `linux-x86-64`
- `linux-aarch64`
- `windows-x86-64`
- `windows-aarch64`
- `macos-x86-64`
- `macos-aarch64`
- `android-aarch64`

> [!NOTE]
> You will likely require some additional setup or dependencies on your system such as Windows libraries when targeting that platform.

## Using another compiler

If you have an alternate compiler on your system, you can override the default compiler lde uses (clang) with the `SEA_CC` env var.

```sh
SEA_CC=clang lde compile
```

> [!WARNING]
> You should rarely, if ever, need to use this.

This is used by lde to forcibly compile on windows with the llvm-mingw clang in CI, where the toolchain download is not an option.
