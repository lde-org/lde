---
title: Runtime
order: 0
---

# Runtime

## What is a runtime?

When we use a programming language, 99% of the time you are using a runtime which provides standard functionality for you.

For example:
1. JavaScript technically does not provide a `fetch` function for you. Your browser is the runtime that provides it to JavaScript.
2. C code cannot run without the C runtime, ie MSVCRT on Windows.

Lua is the same, but for runtimes, typically it is whatever program embedded lua in itself. For example, a game might provide a killEnemy() function as part of its runtime, while this is not a standard lua function.

The core part of the language is known as the "engine", this is what Lua 5.5 are, what JavaScriptCore is, and what LuaJIT is.

> [!NOTE]
> Ultimately, the engine can be interchangeable, the lde runtime is what counts. Lua 5.5 and any other lua C api compatible engines could be supported by lde. Although this is not true at the moment.

## What is the lde runtime?

The lde runtime is a custom runtime built atop of the LuaJIT engine that is shipped with lde. It is used by `lde run` and runs your code.

It uses the latest version of LuaJIT so you can use things like their new [3.0 Syntax Extensions](https://github.com/LuaJIT/LuaJIT/issues/1475)

## How is it different from LuaJIT?

### Modifications

At the moment, lde does not modify LuaJIT much beyond fixes for platforms like Android where necessary (Termux has to ship these in their standard lua package).

> [!NOTE]
> You can find our LuaJIT fork here: https://github.com/lde-org/luajit

### Standard Library

No standard library is shipped beyond what is provided during builds in `lde-build` or tests with `lde-test`.

In the future, one could be implemented similar to what existing Lua runtimes like [Luvit](https://luvit.io/), [Lune](https://github.com/lune-org/lune) and other language runtimes do.

### Other Features

Some nice features not necessarily a part of the runtime, but relevant, are profiler additions, watch mode, hot reloading and support for alternative languages like Teal and Moonscript.

You can read more in the features list on the sidebar.
