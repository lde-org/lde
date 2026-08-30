---
title: Porting From LuaRocks
order: 9
---

# Porting to lde

LuaRocks packages are supported out of the box in lde and should have no issue running.

But, for the intended lde experience, you may intend to port your project to lde, to publish it on the registry, or for better performance.

## File Structure

By default, LuaRocks allows you to arbitrarily define require() paths for each individual file. This means that lde needs to do more work to copy these files to specific locations for your package to work.

By contrast, lde requires all files to be in a `./src/` directory, and requires are based on the file path relative to the src path of a package.

For example, if your package is named `dominator`, and you have a file `./src/foo/qux.lua`, then you'll need to `require("dominator.foo.qux")` to access that file both in your own package and in other packages that depend on it. This allows for the simplicity of lde's require system which intentionally doesn't diverge from lua's natural behavior.

## Native Modules

LuaRocks supports building projects with tools like `make`, `cmake`, etc out of the box (well, provided you have the necessary tools installed).

But this comes with the burden of specifically providing configurations for each different tool and platform. A simpler approach is used for lde.

Instead, `build.lua` scripts are used to define how your package should be built, which gives you a clean api to programmatically run a C compiler, run shell scripts and fetch files over the web. Everything your script writes lands in `./target/<dependency name>/*`.

For example, this can be as simple as a `build:sh("make")` followed by a `build:copy` of your output binary into the output directory. Paths passed to `build:sh` and `build:cc` are relative to the package directory, so use the `build.outDir` field to target the output.

For more info, read about [C Module Support](/docs/general/misc/c-module-support).

## Publishing to LDE

Refer to the [Publishing to LDE](/docs/package-manager/guides/publishing-to-lde) guide!
