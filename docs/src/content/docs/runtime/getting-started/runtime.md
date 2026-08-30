---
title: Runtime
order: 0
---

# Runtime

By default, `lde run` uses the LDE runtime, which embeds LuaJIT through the Lua C API. It's the same LuaJIT fork that lde itself runs on, so your project runs on the exact same engine as the tools you use to build it.

This is useful so users don't need to have any version of lua installed on their system to run your project, since the LDE runtime is bundled with LDE itself automatically.

## Isolation

Every program runs in a fresh, isolated guest state. `lde run`, `lde test`, `lde -e`, and `lde ./file.lua` all get a clean `_G` and a fresh `package.loaded` — nothing leaks between runs, and your code never reaches lde's own internals. Error traces and profiles show only your code.
