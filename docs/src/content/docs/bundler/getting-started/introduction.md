---
title: Introduction
order: 0
---

You can compile your lua program into single files using lde.

## Lua files

Run this to bundle your project and all of its dependencies into a single .lua file

```sh
lde bundle
```

> [!TIP]
> You can also pass `--bytecode` to compile into a luajit bytecode file (smaller and faster to run). Note you will need to run the file with the same version of LuaJIT lde supports.

## Native executables

Using lde's C compilation support, you can compile your lua program into a native executable.

```sh
lde compile
```

The created executable can run without lua, lde, or any of your dependencies on the user's system. It just *works*.

> [!TIP]
> lde itself is created with `lde compile`!

### How does it work?

This isn't a simple "slaps data in a linker section on an existing binary" like many single executable bundlers do (ie Bun or Deno).

It uses the native C compiler lde incorporates to create a new executable linking luajit with any files in your `/target` folder bundled in as bytecode alongside any native dependencies (.so, .dll).

### Cross Compilation

You can also cross compile your program for different platforms using the `--target` flag.

> [!WARNING]
> Support for cross compilation is best effort and experimental.

```sh
lde compile --target <target>
```

You can read more at [Cross Compilation](/docs/bundler/features/cross-compilation).
