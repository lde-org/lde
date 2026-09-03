---
title: Moonscript Support
order: 1
---

[MoonScript](https://moonscript.org/) is a dynamic whitespace based language that compiles to lua.

Support for MoonScript ships built-in to lde.

> [!TIP]
> No configuration is needed to use MoonScript with lde.

You can simply write `.moon` files and they will be compiled ahead of time when running, testing, or bundling.

## Quickstart

1. Run this and cd into it:

```sh
lde new --language moonscript ./hello-moon
```

2. Replace `src/init.moon` with:

```moonscript src/init.moon
greet = require("hello-moon.greet")
n = 40
print(greet("moon") .. " " .. tostring(n + 2))
```

3. Make `src/greet.moon`:

```moonscript src/greet.moon
greet = (name) -> "hello " .. name
return greet
```

4. Run it with `lde run`

The output is:

```
hello, moon 42
```

The file `src/init.moon` is the entry point. This is the same as `src/init.lua` for packages that use Lua.
