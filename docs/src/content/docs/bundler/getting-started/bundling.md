---
title: Bundling A Lua File
order: 2
---

# Bundling to a Lua File

`lde bundle` takes your project and all of its installed dependencies and merges them into a single self-contained `.lua` file. The result can be run with any LuaJIT runtime without needing lde installed.

## How it works

lde builds your project, installs dependencies into `./target/`, then walks every `.lua` file in that directory. Each file is registered as a `package.preload` entry under its module name, so `require()` resolves them from the bundle rather than the filesystem. The final line calls your package's entrypoint.

## Basic usage

```sh
lde bundle
```

This outputs `<name>.lua` in your project root.

## Custom output path

```sh
lde bundle --outfile dist/myapp.lua
```

## Bytecode bundle

Pass `--bytecode` to compile each module to LuaJIT bytecode before embedding. The output is smaller and faster to load, but is only compatible with the LuaJIT version bundled in LDE. It will not run on Lua 5.x or a different LuaJIT build.

```sh
lde bundle --bytecode
```

The bytecode bundle is itself compiled as a single chunk, so the output is a binary `.lua` file.
