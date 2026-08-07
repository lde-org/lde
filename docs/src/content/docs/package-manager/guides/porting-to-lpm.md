---
title: Porting to LDE
order: 2
---

# Porting to LDE

LDE now supports Luarocks packages. But the experience is ultimately not as great as fully native LDE packages, which you might prefer to avoid file copies and get better LuaCATs typing experience.

This guide will tell you how to port your projects to LDE.

## File Structure

Move all of your files into a `./src/` directory at the top level of your project.
At build time, this will be moved into `./target/<dependency name>/*`.

## Requires

Change your require pattern to be absolute, and include the name of your package.

For example, a project with `./src/foo/qux.lua` named `redestro`, with an entrypoint at `./src/init.lua` that requires that file would do so via `require("redestro.foo.qux")`.

## Native Modules

Create a `build.lua` file that uses the [`lde-build`](/docs/package-manager/dependencies/build-scripts) API. Everything your script writes lands in `./target/<dependency name>/*`.

For example, this can be as simple as a `build:sh("make")` followed by a `build:copy` of your output binary into the output directory. Paths passed to `build:sh` and `build:cc` are relative to the package directory, so use the `build.outDir` field to target the output.

For more info, read about [C Module Support](/docs/package-manager/dependencies/c-module-support).

## Publishing to LDE

Refer to the [Publishing to LDE](/docs/package-manager/guides/publishing-to-lpm) guide!
