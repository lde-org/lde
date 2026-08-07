---
title: Build Scripts
order: 5
---

# Build Scripts

Projects may contain a build script at the root, named `build.lua`. When a build script is present, lde runs it instead of symlinking `src/`. Build scripts are for building native dependencies, preprocessing code from one language to another, or generating files. ([Teal to Lua](/docs/runtime/guides/teal) does not need a build script.)

When a build script runs, lde copies the source directory into the output directory first, so the files are mutable and not symlinked. Everything the script produces ends up in `target/`, where users can require it.

## The `lde-build` API

A build script gets its context through `lde-build`:

```lua
local build = require("lde-build")
```

Every path is relative to the output directory (`target/<name>` by default). The legacy name `lpm-build` also resolves, for older scripts.

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

Runs a shell command. Fails the build when the command exits non-zero.

```lua
build:sh("make")
build:sh("./configure --prefix=.")
```

### `cc(args)`

Runs the C compiler with the given argument list. Returns stdout and stderr. Fails the build when the compiler exits non-zero.

`cc` uses the same toolchain that Windows gets bundled. On Windows this is the bundled Clang/LLD toolchain with its tools on `PATH`. Elsewhere it is the system `gcc`.

```lua
build:cc({ "-c", "foo.c", "-o", "foo.o" })
build:cc({ "foo.o", "-o", "foo.so" })
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
build:cc({ "-c", "foo.c", "-o", "foo.o" })
build:cc({ "foo.o", "-o", "foo.so" })
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
