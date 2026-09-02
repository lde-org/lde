---
title: Native Modules
order: 11
---

# Native Modules

Native modules are supported in lde projects via build scripts. You simply use the `lde-build` api to download any sources you need, and compile the output to the target directory.

## Example

This example builds a module named `socket.core` for a package named `socket`. The library lands at `target/socket/core.so` (or `.dll` on Windows), so `require("socket.core")` finds it.

```lua build.lua
local build = require("lde-build")

-- src/ is copied into the output directory before the script runs, so the
-- source is available at build.outDir .. "/socket.c". build:cc resolves
-- paths from the package directory, so prefix arguments with build.outDir.
local ext = jit.os == "Windows" and "dll" or "so"

build:cc({
	"-shared", "-fPIC",
	"-o", build.outDir .. "/core." .. ext,
	build.outDir .. "/socket.c"
})
```

```lua src/init.lua
local socket = require("socket.core")
print("Here's the output: ", socket)
-- Here's the output: Hello from C!
```

## Compiled Applications

This also works for packages compiled with `lde compile`.

When compiled, lde scans the `target` directory for any shared libraries and saves them into the binary. They are then extracted into a temporary directory at runtime.

They do not require lua on the user's system on Windows, macOS, or Linux, as the binary created exports the LuaJIT symbols from lde.

## Distributing as a Library

This all runs at the build time when someone installs your library, so you should make your build script smart enough to build on multiple platforms and ideally depend on as little as possible.
