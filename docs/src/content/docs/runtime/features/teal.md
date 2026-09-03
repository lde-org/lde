---
title: Teal Support
order: 0
---

[Teal](https://teal-language.org/) is a statically typed dialect of lua by the creator of LuaRocks.

It is intended to become the TypeScript of Lua, and ships its compiler via luarocks.

Teal support ships built-in to lde.

> [!TIP]
> No configuration is needed to use Teal with lde.

Any `.tl` files in your `src` dir will automatically be compiled ahead of time to lua into your `target` directory.

## Quickstart

1. Run this and cd into it:

```sh
lde new --language teal ./hello-teal
```

The scaffold writes `src/init.tl` as the entry point, adds a `check` script to `lde.json` so `lde check` runs the Teal compiler's checker, and drops in a `tlconfig.lua` with `target/` on the include path.

2. Replace `src/init.tl` with:

```lua src/init.tl
local greet = require("hello-teal.greet")

local count: integer = 41
print(greet("world"), count + 1)
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
hello, world    42
```

The file `src/init.tl` is the entry point. This is the same as `src/init.lua` for packages that use Lua.

> [!WARNING]
> Note that teal support is implemented as simply stripping the types and running your code. No type validation is run on `lde run`.

## Type checking with `tl check`

Since no type checking is performed on run, to check your code, you can run the `tl` compiler using `ldx`.

```sh
ldx rocks:tl check -I target src/init.tl
```

This works because lde preserves the `.tl` sources in your `target/` alongside the compiled `.lua` files.

We can add this as a [package script](/docs/general/features/package-scripts) for easy use as `lde check`:

```jsonc
{
	"scripts": {
		"check": "ldx rocks:tl check -I target src/init.tl src/greet.tl"
	}
}
```

Then you can simply run a type check as so:

```sh
lde check
```

> [!TIP]
> Only the compiled .lua files are stored in `lde bundle` / `lde compile` outputs, so they won't waste space in your bundle.
