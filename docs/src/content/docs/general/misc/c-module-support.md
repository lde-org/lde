---
title: C Module Support
order: 11
---

# C Module Support

C modules are supported in LDE projects via build scripts.

The process is simple: compile your C source into a shared library and place it inside your package's output directory (`target/<name>/`). lde adds an entry to your `package.cpath` which resolves shared libraries the same way it resolves Lua files in your `target` directory — so the library is `require`d like any other module in your package.

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

The exported symbol must match the require name: `require("socket.core")` looks for `luaopen_socket_core`. The example declares only the Lua C API functions it uses, so it compiles without LuaJIT headers on the machine. Larger modules usually `#include "lua.h"` and arrange for the headers themselves — for example by fetching them with `build:fetch` or driving a full build system with `build:sh`.

```c socket.c
#include <stddef.h>

typedef struct lua_State lua_State;
typedef int (*lua_CFunction)(lua_State *L);

extern void lua_pushstring(lua_State *L, const char *s);

int luaopen_socket_core(lua_State *L) {
	lua_pushstring(L, "Hello from C!");
	return 1;
}
```

```lua src/init.lua
local socket = require("socket.core")
print("Here's the output: ", socket)
-- Here's the output: Hello from C!
```

## Support for compiled applications

This also works for projects compiled with `lde compile` by scanning and saving any shared libraries from `target` into the binary, and extracting them into a temporary directory at runtime.

They are then resolved via a `package.preload` lookup on require(), same as lua files.

They do not require lua on the user's system on Windows, macOS, or Linux, as the binary created exports the LuaJIT symbols from LDE.

## Distributing as a Library

This all runs at the build time when someone installs your library, so you should make your build script smart enough to build on multiple platforms and ideally depend on as little as possible.
