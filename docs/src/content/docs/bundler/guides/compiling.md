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

## Native modules

Shared libraries built by a `build.lua` script are automatically included. See [C Module Support](/docs/package-manager/dependencies/c-module-support) for how to produce them.

> The binary exports LuaJIT symbols on Windows, macOS, and Linux, so native modules don't require a separate Lua installation.

## See also

- [Analyzing Binary Bloat](/docs/bundler/guides/bloat) — see what makes up the compiled binary, per dependency and per file.

