---
title: Teal Support
order: 0
---

# Teal Support

Teal support ships built-in to lde. Any `.tl` files in your `src` dir will automatically be compiled ahead of time to lua into your `target` directory.

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

## Type checking with `tl check`

Every Teal package — including dependencies — keeps its `.tl` sources in `target/` next to the compiled `.lua` files. That lets the Teal compiler's own checker resolve `require(...)` against your dependencies with full type info:

```sh
tl check -I target src/init.tl
```

Or add the directory to your `tlconfig.lua`:

```lua
return {
	include_dir = { "target" },
}
```

Wire it up as a project script so `lde check` runs the checker — lde builds the package first, so `target/` is always up to date:

```jsonc
{
	"scripts": {
		"check": "tl check -I target src/init.tl src/greet.tl"
	}
}
```

```sh
lde check
```

List every `.tl` file in `src/` you want checked (add new ones as you create them), and make sure the `tl` CLI is on your `PATH`. The script is just a shell command executed from the package root, so `lde run check` works too.

The checker looks up `require("mylib.foo")` as `target/mylib/foo.tl` (or `.d.tl`), so your own modules and every dependency's modules type-check from `target/`. Only the compiled `.lua` files ever end up in `lde bundle` / `lde compile` output — the preserved `.tl` sources are never bundled.
