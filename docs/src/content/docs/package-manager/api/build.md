---
title: Build Api
order: 0
---

The `lde-build` api is crucial to writing clean, cross platform and safe [build scripts](/docs/package-manager/features/build-scripts).

It provides filesystem helpers, C compilation, and web fetching functionality, allowing you to do things like fetch a tarball, compile it and write it into your target directory.

A build script gets the api by requiring `lde-build`:

```lua
local build = require("lde-build")
```

> [!NOTE]
> Every method below uses paths relative to the output directory. So, `build:write("foo.c", ...)` writes to `target/<your package>/foo.c`.

## Fields

### `Build.outDir: string`

The path of the output directory: where lde copied your sources and where everything the script writes ends up. Relative to your package, this will be `/target/<yourpackage>`.

### `Build.target: string`

The compiler target triple of the current build: the target platform's triple when cross-compiling with `lde compile --target`, the host triple otherwise. Useful for naming artifacts, e.g. `build:write("lib-" .. build.target .. ".so", ...)`.

## Methods

### `Build:fetch(url: string) -> string`

Performs an HTTP GET and returns the response body as a string. Errors if the request fails.

```lua
local source = build:fetch("https://example.com/foo.c")
build:write("foo.c", source)
```

### `Build:write(rel: string, content: string)`

Writes `content` to the file at `rel` inside the output directory, creating parent directories as needed.

```lua
build:write("init.lua", "return require('src.foo')")
```

### `Build:read(rel: string) -> string`

Reads and returns the contents of the file at `rel` inside the output directory. Errors if the file is missing.

```lua
local init = build:read("init.lua")
```

### `Build:extract(rel: string, dest: string)`

Extracts the archive at `rel` into `dest`.

```lua
local tarball = build:fetch("https://example.com/lib.tar.gz")
build:write("lib.tar.gz", tarball)
build:extract("lib.tar.gz", "lib")
```

### `Build:copy(rel: string, dest: string)`

Copies the file or directory at `rel` to `dest`, recursively copying any folders.

> [!NOTE]
> This copy is done atomically, so it is safe to replace running shared libraries.

```lua
build:copy("src/lfs.so", "../lfs.so")
```

### `Build:move(rel: string, dest: string)`

Moves or renames `rel` to `dest`, both inside the output directory. Errors if the move fails.

```lua
build:move("tmp/init.lua", "init.lua")
```

### `Build:delete(rel: string)`

Deletes the file or directory at `rel` inside the output directory. Errors if the delete fails.

```lua
build:delete("lib.tar.gz")
```

### `Build:exists(rel: string) -> boolean`

Returns `true` when `rel` exists inside the output directory.

```lua
if build:exists("config.h") then
	build:write("config.h", "#define VERSION 1")
end
```

### `Build:sh(cmd: string)`

Runs `cmd` as a shell command with `cmd.exe` on Windows and `/bin/sh` otherwise.

> [!WARNING]
> In the future, this may use `sh` on windows as well.

```lua
build:sh("make")
build:sh("./configure --prefix=" .. build.outDir)
```

### `Build:cc(args: string[]) -> stdout: string, stderr: string`

Runs the C compiler with `args` as its argument list, with the output directory as the working directory.

```lua
local out = build.outDir
build:cc({ "-c", out .. "/foo.c", "-o", out .. "/foo.o" })
local stdout, stderr = build:cc({ out .. "/foo.o", "-o", out .. "/foo.so" })
```
