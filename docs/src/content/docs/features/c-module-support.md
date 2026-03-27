---
title: C Module Support
order: 5
---

# C Module Support

C modules are supported in LDE projects via build scripts.

The process is simple, build your project using CMake, GCC, or anything available to your project, and then extract a `.so` or `.dll` into the output directory of your project, which is `$LDE_OUTPUT_DIR` (which you can get with `os.getenv("LDE_OUTPUT_DIR")`)

This works because LDE also adds an entry to your `package.cpath` which resolves for shared libraries in the same way it resolves for lua files in your `target` directory.

## Example

> build.lua

```lua
local outDir = os.getenv("LDE_OUTPUT_DIR")

local pathSep = string.sub(package.config, 1, 1)
local libraryExt = jit.os == "Windows" and "dll" or jit.os == "Darwin" and "dylib" or "so"
local libraryName = "core"

local scriptPath = debug.getinfo(1, "S").source:sub(2):match("(.*/)")

local function join(...)
	return table.concat({ ... }, pathSep)
end

local outPath = join(outDir, libraryName .. "." .. libraryExt)
local inPath = join(scriptPath, "socket.c")

os.execute("gcc -shared -fPIC -o " .. outPath .. " " .. inPath)
```

> socket.c

```c
#include "lua.h"

int luaopen_socket_core(lua_State *L) {
  lua_pushstring(L, "Hello from C!");
  return 1;
}
```

> src/init.lua

```lua
local socket = require("socket.core")
print("Here's the output: ", socket)
-- Here's the output: Hello from C!
```

## Support for compiled applications

This also works for projects compiled with `lde compile` by scanning and saving any shared libraries from `target` into the binary, and extracting them into a temporary directory at runtime.

They are then resolved via a `package.preload` lookup on require(), same as lua files.

They do not require lua on the user's system on Linux as the binary created exports the LuaJIT symbols from LDE. **_This is not the case on Windows which has no analog to this, so you might have to bundle a lua shared library with your project._**

## Distributing as a Library

This all runs at the build time when someone installs your library, so you should make your build script smart enough to build on multiple platforms and ideally depend on as little as possible.
