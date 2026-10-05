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

### `Build.features: table<string, boolean>`

The [feature flags](/docs/package-manager/features/optional-dependencies) enabled for this build, keyed by flag name, so `build.features.windows` is `true` on Windows. Prefer `build:feature(name)` unless you are iterating over the set.

## Methods

### `Build:feature(name: string) -> boolean`

Whether the named feature flag is enabled for this build. Use it to emit only the backend the current platform needs, or to compile optional functionality:

```lua
if build:feature("unix") then
	build:cc({ "cc", "-shared", "-fPIC", "src/posix.c", "-o", "mypackage/posix.so" })
elseif build:feature("windows") then
	build:cc({ "cc", "-shared", "src/win32.c", "-o", "mypackage/win32.dll" })
end
```

The platform's own flags (`windows`, `linux`, `macos`, `bsd`, `unix`) are always on for the matching platform, and any flag a dependent asked for is on whether or not your manifest declares it — so a flag is allowed to drive nothing but your build script.

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

### `Build:scan(rel: string, glob?: string) -> string[]`

Lists every file under `rel`, recursively. The paths come back relative to the output directory, so each one can be handed straight back to `Build:read`:

```lua
for _, file in ipairs(build:scan("assets")) do
	build:write(file .. ".lua", "return [==[" .. build:read(file) .. "]==]")
end
```

`glob` optionally filters the paths relative to `rel` (`**` by default). `*` and `?` match within a single path segment and `**` matches across segments

```lua
build:scan("icons", "**/*.qoi") -- every icon, at any depth
build:scan("icons", "*.qoi")    -- only the icons in icons/ itself
```

> [!NOTE]
> Scanning a directory that does not exist returns an empty list.

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
