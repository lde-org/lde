---
title: Compiling to an Executable
order: 2
---

# Compiling to an Executable

`lde compile` produces a standalone native executable that bundles your Lua code, all dependencies, and the LuaJIT runtime into a single binary. Users need no Lua installation to run it.

## How it works

lde builds and installs your dependencies, then walks `./target/` collecting every `.lua` file and every native shared library (`.so` / `.dll` / `.dylib`). Lua files are embedded as preloaded modules. Native libraries are packed into the binary and extracted to a temporary directory at runtime, then resolved via `package.preload`. The binary includes the LDE runtime (LuaJIT) and is not compatible with standard Lua. See [Requirements](/docs/bundler/getting-started/requirements) for compiler prerequisites.

## Basic usage

```sh
lde compile
```

Outputs `<name>` (or `<name>.exe` on Windows) in your project root.

## Custom output path

```sh
lde compile --outfile dist/myapp
```

On Windows `.exe` is appended automatically if not already present.

## Cross-compilation

Compile for any of the targets lde ships in its GitHub releases:

```sh
lde compile --target=windows-x86-64
lde compile --target=linux-aarch64
lde compile --target=android-aarch64
```

The available targets are `linux-x86-64`, `linux-aarch64`, `windows-x86-64`, `windows-aarch64`, `macos-x86-64`, `macos-aarch64`, and `android-aarch64`. A `--target` matching the host behaves exactly like a plain `lde compile`. Cross-compiled output defaults to `<name>-<target>` (with `.exe` appended for Windows targets).

Cross-compilation resolves clang automatically — no `SEA_CC` needed:

- **Windows targets** work out of the box on Windows hosts: the bundled toolchain is clang/LLD with the mingw sysroot, so `--target=windows-x86-64` and `--target=windows-aarch64` just work.
- **Other targets** use a clang on PATH. The target's LuaJIT runtime is downloaded automatically; if the target needs a sysroot clang can't reach (e.g. cross-compiling `linux-aarch64` on an x86-64 machine without an aarch64 sysroot), set `SEA_CC` to a clang that has one.

Cross links prefer **lld** and clang's own runtime (compiler-rt) over gcc's libgcc, so a plain clang can link a target without the target's gcc being installed. What is still required is the target's **C runtime library** — either the target's compiler-rt builtins (bundled with llvm-mingw-style toolchains) or its libgcc (e.g. `dnf install mingw64-gcc` on Fedora). If it's missing, the link fails with `cannot find -lgcc` and lde points at exactly what's missing.

## Native modules

Shared libraries built by a `build.lua` script are automatically included. See [C Module Support](/docs/package-manager/dependencies/c-module-support) for how to produce them.

Native dependencies are built for the **target** when cross-compiling: `build:cc()` invokes the cross compiler (clang with `--target=<triple>`), the `CC`/`LD` environment variables passed to `build:sh()` subprocesses (make, cmake, ...) use it too, and `build.target` reports the triple being built for (e.g. `aarch64-linux-gnu`; the host triple on native builds). Build scripts that download or compile platform-specific code should branch on `build.target` instead of `jit.os` so they work under `--target`.

> The binary exports LuaJIT symbols on Windows, macOS, and Linux, so native modules don't require a separate Lua installation.

## See also

- [Analyzing Binary Bloat](/docs/bundler/guides/bloat) — see what makes up the compiled binary, per dependency and per file.

