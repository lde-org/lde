---
title: Porting luarocks libraries to lpm
order: 2
---

# Porting from LuaRocks

## How LuaRocks manages projects

The way LuaRocks manages projects is by allowing you to provide specifically _how_ a user calls your library via require. For example, you can just arbitrarily mark a file in your project as module `foo.bar.qux` and users will have to require it via `require("foo.bar.qux")`.

This is useful at times, but it also means you have to manually do this and that there's no consistency across projects. LPM takes a different approach.

## How LPM manages projects

Entrypoints are _always_ stored at `./src/init.lua`, which is output at `./target/depname/init.lua`. This means that `require("depname")` is simply resolved via a package.path addition of `./target/?/init.lua`.

This is extended for non-entrypoint files via `./target/?.lua`, allowing you to import any files in the source of a module.

## Okay, so how do I port my project?

The simplest case is just that you can _hopefully_ just create a shim at `./src/init.lua` and require your old entrypoint. If it works, great!

If not, you'll have to get creative, or restructure to fit LPM.

There are unfortunately no plans to change this rigid structure, as it is a core part of how LPM works so simply and across runtimes.

## What if I use native dependencies?

This is where it gets tricky. Luarocks has functionalities specifically in their rockspecs to define how a module is to be built for use.

LPM went for a very general, and simplistic approach. You are allowed to create a top level `build.lua` file which gets access to an environment variable `LPM_OUTPUT_DIR` which will map to the folder where your project will be built, ie `/target/myproject`.

Then it's entirely up to your `build.lua` script to do whatever is needed to build it to that output directory. It can run commands, executables, anything it wants.

For an example of this, see the port of [luafilesystem](https://github.com/lunarmodules/luafilesystem) to LPM's build script: https://github.com/codebycruz/luafilesystem/blob/master/build.lua

## Examples

As one of the earliest test-cases of LPM, I ported over busted, and all of its projects in their entirety.

You can find this here: https://github.com/codebycruz/busted
