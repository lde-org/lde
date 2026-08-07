---
title: Teal Support
order: 1
---

# Teal Support

Teal support ships built-in to lde. Any `.tl` files in your `src` dir will automatically be compiled ahead of time to lua into your `target` directory.

## Quickstart

1. Run this and cd into it:

```sh
lde new ./hello-teal
```

2. Replace `src/init.lua` with `src/init.tl`:

```lua src/init.tl
local greet = require("hello-teal.greet")

local count: integer = 41
print(greet("world") .. " — " .. tostring(count + 1))
```

3. Make `src/greet.tl`:

```lua src/greet.tl
local function greet(name: string): string
	return "hello, " .. name
end

return greet
```

4. Run it with `lde run`

The output is:

```
hello, world — 42
```

The file `src/init.tl` is the entry point. This is the same as `src/init.lua` for packages that use Lua.
