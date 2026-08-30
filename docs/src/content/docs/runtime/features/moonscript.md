---
title: Moonscript Support
order: 1
---

# Moonscript Support

Moonscript support ships built-in to lde. Any `.moon` files in your `src` dir will automatically be compiled ahead of time to lua into your `target` directory.

## Quickstart

1. Run this and cd into it:

```sh
lde new --language moonscript ./hello-moon
```

The scaffold writes `src/init.moon` as the entry point; no other configuration is needed as `.moon` files compile to Lua automatically.

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
