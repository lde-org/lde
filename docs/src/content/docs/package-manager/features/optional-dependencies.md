---
title: Optional Dependencies
order: 2
---

lde supports optional dependencies that are only installed when a specific feature flag is enabled. This is useful for platform-specific dependencies or add-ons that not every user of your package needs.

## Adding Optional Dependencies

Add an `"optional"` field to any dependency in your `lde.json`:

```json
"dependencies": {
  "winapi": { "git": "https://github.com/example/winapi", "optional": true }
}
```

## Defining features

Features are named groups. You define them under the `"features"` key in `lde.json`, where each key is a feature name and the value is a list of what the feature turns on:

```json
"dependencies": {
  "winapi": { "git": "https://github.com/example/winapi", "optional": true },
  "luaposix": { "luarocks": "luaposix", "optional": true }
},
"features": {
  "windows": ["winapi"],
  "linux": ["luaposix"],
  "macos": ["luaposix"]
}
```

## Gating files

A feature can also omit files from your bundle. Name the module exactly as you would `require()` it and it will be left out from the bundle.

```json
"features": {
  "vulkan": ["mypackage.vulkan"],
  "unix": ["mypackage.raw.windows"]
}
```

You can mix and match dependencies and specific files.

```json
"features": {
  "unix": ["luaposix", "mypackage.raw.windows"]
}
```

Exclusion matches on the *module* a file implements, not on its filename, so a single entry covers every form that module can ship in. `mypackage.native.core` drops all of:

- native/core.lua
- native/core/init.lua
- native/core.so
- native/core.dll
- native/core.dylib


> [!NOTE]
> These exclusions only apply during bundling via compile or bundle, so for example ./target during development will still symlink and not respect this.

## Built-in features

lde automatically activates feature flags based on the current operating system:

| Feature flag | Platform                      |
| ------------ | ----------------------------- |
| `windows`    | Windows                       |
| `linux`      | Linux                         |
| `macos`      | macOS                         |
| `bsd`        | FreeBSD and other BSDs        |
| `unix`       | any non-Windows platform      |

This means you can gate dependencies and files by OS without any extra configuration. `unix` is what you usually want when there is one POSIX backend and one Windows backend:

```json
"features": {
  "windows": ["mypackage.raw.posix", "winapi"],
  "unix":    ["mypackage.raw.windows"]
}
```

## Detecting features at build time

A build script can ask whether a flag is on with `build:feature(name)`. This is how a package keeps several backends in one repository and compiles only the one that runs:

```lua
local build = require("lde-build")

if build:feature("unix") then
	build:cc({ "cc", "-shared", "-fPIC", "src/posix.c", "-o", "mypackage/posix.so" })
elseif build:feature("windows") then
	build:cc({ "cc", "-shared", "src/win32.c", "-o", "mypackage/win32.dll" })
end
```

`build:feature` sees the platform flags, plus any flag your dependents asked for. A flag does not have to be declared in `features` to be visible here — if a consumer requests one, `build:feature` reports it as on, so a build script can be the only thing a flag drives. The full set is also available as `build.features`.

See the [Build Api](/docs/package-manager/api/build) for the rest of the build API.

## Enabling Features

The features you define are for your own package. When you depend on a package that defines features of its own, you opt into them per dependency by adding a `"features"` key to its entry in your `lde.json`:

```json
"dependencies": {
  "my-package": {
    "git": "https://github.com/example/my-package",
    "features": ["windows", "sdl2"]
  }
}
```

You never have to name a platform flag: lde turns the right one on for every package by itself.
