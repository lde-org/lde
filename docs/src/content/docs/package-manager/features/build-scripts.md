---
title: Build Scripts
order: 0
---

To support native dependencies, lde supports build scripts. These are stored at the root of your package, named `build.lua`.

If one is present, instead of symlinking your src directory to your target directory, lde will copy your source folder into target, and then run the build script to populate the newly created dir.

This allows you to do things like preprocess your files, pull in and compile a C module for use in lua, etc. This is all accomplished using the [lde-build](/docs/package-manager/api/build) API.

> [!WARNING]
> At the moment, build.lua scripts run without restrictions. This may not be true in the future, so use the `lde-build` API for all build script tasks.

## Caching

A build script runs only when its inputs change. lde records the size, mtime, and hash of every file under `src/`, plus `lde.json` and `build.lua`. An unchanged package skips the build script and keeps the previous output.

## Examples

### Native module

This example downloads a C source file, compiles it, and places the resulting `.so` next to the package entry point:

```lua build.lua
local build = require("lde-build")

local source = build:fetch("https://example.com/foo.c")
build:write("foo.c", source)
build:cc({ "-c", build.outDir .. "/foo.c", "-o", build.outDir .. "/foo.o" })
build:cc({ build.outDir .. "/foo.o", "-o", build.outDir .. "/foo.so" })
```

### Preprocessing

This example is used in the [hood](https://github.com/bycruz/hood) graphics library to include C header files into `ffi.cdefs`:

```lua build.lua
local build = require("lde-build")

local init = build:read("init.lua")

local escapes = {
	["\\"] = "\\\\",
	["\""] = "\\\"",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t"
}

local preprocessed = string.gsub(init, "%[%[#embed \"([^\"]+)\"%]%]", function(filename)
	local content = build:read(filename)
	return '"' .. (content:gsub("[\\\"\n\r\t]", escapes)) .. '"'
end)

build:write("init.lua", preprocessed)
```
