---
title: JIT Debugging
order: 3
---

A common pattern for developers using LuaJIT is to maximize the amount of lua code that can be JIT compiled for performance.

The [profiler](/docs/runtime/features/profiling) is a good starting point, but it isn't super specific due to its minimal overhead.

Typical LuaJIT developers will use the `-jv` flag (jit verbose) which will hook into the JIT compiler and print when it fails and why.

This functionality is also exposed by lde with the `--jit` flag:

```sh
lde run --jit
```

This will run your code and print to your console whenever a function fails to compile, giving you a brief location and reason.

![JIT Debugging](/docs-assets/jit-brief.avif)

When your program terminates, it will give you a complete overview of all of these fails alongside syntax highlighted locations where they occurred.

![JIT End](/docs-assets/jit-end.avif)

> [!TIP]
> Did I mention this also works with teal and moonscript?
