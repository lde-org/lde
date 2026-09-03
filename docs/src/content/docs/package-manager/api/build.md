---
title: Build Api
order: 0
---

The `lde-build` api is crucial to writing clean, cross platform and safe [build scripts](/docs/package-manager/features/build-scripts).

It provides filesystem helpers, C compilation, and web fetching functionality, allowing you to do things like fetch a tarball, compile it and write it into your target directory.

## Fields

### `Build.outDir: string`

This contains a path to the output directory to the build.

Specifically, this will be `/target/<yourpackage>`

## Methods

### `Build:fetch(url: string) -> string`

This function does blah
