---
title: Moonscript Support
order: 2
---

# Moonscript Support

Moonscript support ships built-in to lde. Any `.moon` files in your `src` dir will automatically be compiled ahead of time to lua into your `target` directory.

## Quickstart

1. Run this and cd into it:

```sh
lde new ./hello-moon
```

2. Replace `src/init.lua` with `src/init.moon`:

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
