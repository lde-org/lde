---
title: Build Scripts
order: 0
---

Projects may contain a build script at the root, named `build.lua`. When a build script is present, lde runs it instead of symlinking `src/`. Build scripts are for building native dependencies, preprocessing code from one language to another, or generating files. ([Teal to Lua](/docs/runtime/features/teal) does not need a build script.)

When a build script runs, lde copies the source directory into the output directory first, so the files are mutable and not symlinked. Everything the script produces ends up in `target/`, where users can require it.

> **NOTE:** Build scripts run without restrictions. They have full access to the Lua standard library, the shell, and the filesystem. This behavior is not guaranteed. A future version of lde can restrict build scripts. Use the `lde-build` API for all build script tasks. It is the supported interface. Scripts that use raw `os`, `io`, or other direct system access can break without warning.

## The `lde-build` API

A build script gets its context through `lde-build`:

```lua
local build = require("lde-build")
```

Every path in the file methods is relative to the output directory (`target/<name>` by default). `build.sh` and `build.cc` run with the package directory as the working directory, so paths you pass to them must be absolute or prefixed with `build.outDir`. The legacy name `lpm-build` also resolves, for older scripts.

### `outDir` and `gccBin`

The instance also exposes its configuration as fields. `build.outDir` is the absolute path of the output directory and `build.gccBin` is the path of the C compiler. They are handy when composing commands for `sh` and `cc`, whose paths are relative to the package directory rather than the output directory.

### `fetch(url)`

Downloads a URL and returns the response body as a string. Errors if the request fails.

```lua
local source = build:fetch("https://example.com/foo.c")
build:write("foo.c", source)
```

### `write(rel, content)`

Writes `content` to the file at `rel` inside the output directory. Creates parent directories as needed. Errors if the write fails.

```lua
build:write("init.lua", "return require('src.foo')")
```

### `read(rel)`

Reads and returns the file at `rel` inside the output directory. Errors if the file is missing.

```lua
local init = build:read("init.lua")
```

### `extract(rel, dest)`

Extracts the archive at `rel` into `dest`. Both paths are relative to the output directory.

```lua
local tarball = build:fetch("https://example.com/lib.tar.gz")
build:write("lib.tar.gz", tarball)
build:extract("lib.tar.gz", "lib")
```

### `copy(rel, dest)`

Copies the file at `rel` to `dest`, both relative to the output directory.

```lua
build:copy("src/lfs.so", "../lfs.so")
```

### `move(rel, dest)`

Moves the file at `rel` to `dest`, both relative to the output directory.

```lua
build:move("tmp/init.lua", "init.lua")
```

### `delete(rel)`

Deletes the file at `rel` inside the output directory.

```lua
build:delete("lib.tar.gz")
```

### `exists(rel)`

Returns whether the file at `rel` exists inside the output directory.

```lua
if build:exists("config.h") then
  build:write("config.h", "#define VERSION 1")
end
```

### `sh(cmd)`

Runs a shell command from the package directory (not the output directory). Fails the build when the command exits non-zero.

```lua
build:sh("make")
build:sh("./configure --prefix=" .. build.outDir)
```

### `cc(args)`

Runs the C compiler with the given argument list. Returns stdout and stderr. Fails the build when the compiler exits non-zero. Paths in `args` are resolved from the package directory — prefix them with `build.outDir` to write into the output.

`cc` uses the same toolchain that Windows gets bundled. On Windows this is the bundled Clang/LLD toolchain with its tools on `PATH`. Elsewhere it is the system `gcc`.

```lua
build:cc({ "-c", build.outDir .. "/foo.c", "-o", build.outDir .. "/foo.o" })
build:cc({ build.outDir .. "/foo.o", "-o", build.outDir .. "/foo.so" })
```

## Output directory

`LDE_OUTPUT_DIR` is still set for compatibility. `os.getenv("LDE_OUTPUT_DIR")` gives the absolute path of the output directory. The API methods are relative to it, so scripts do not need to construct absolute paths.

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

This example is used in the [hood](https://github.com/codebycruz/hood) graphics library to include C header files into `ffi.cdefs`:

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
