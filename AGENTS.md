# lde

`lde` is a package manager and toolkit for Lua. It is built with itself.

You can read full documentation on the official website [lde.sh](https://lde.sh/llms.txt).

## DO NOT USE LuaJIT

**Always use `lde`, never `luajit` directly** (unless you're bootstrapping, in which case, use `minilde.lua`)

Everything you'd need from luajit you can do with lde. And lde does it while properly including dependencies.

```sh
lde -e "print(require('json').encode({x=1}))"  # runs with all project deps available
lde ./file.lua                                  # runs file with project's dep tree
lde run                                         # runs the package entry point (src/init.lua)
```

## Adding Dependencies

Prefer use of the commands over manually editing lde.json.

Never edit lde.lock.

`lde add`, `lde remove`, `lde update`.

## Developing lde

Since lde is built with itself, you work on it like any other lde package:

```sh
lde test # run tests on all packages in monorepo
lde -C ./packages/lde compile
cp lde ~/.lde/lde # install globally
```

### Type Checking

Run `just check` to run Lua Language Server's type checks on the codebase.

Never leave the tree with diagnostics.

## minilde.lua

`minilde.lua` is a minimal bootstrap script for platforms that don't yet have an `lde` binary.

It is to be used only when creating a new platform build from scratch. You shouldn't ever have to use it, outside of using it to edit bootstrap.yml to use.

```sh
luajit minilde.lua run [-- extra-args]   # passes args after '--'
```

## Style

Follow STYLE.md

## Performance

**Minimize allocations**: Reuse tables and use ffi cdata types instead of them to save on allocations.

**Use FFI**: Always use FFI allocs and calls for performance intensive hot paths.

**NEVER** use `ffi.new`, you should be using the `ffi.typeof` constructors instead.

```lua
local Buffer = ffi.typeof("uint8_t[?]")
local buf = Buffer(1024)  -- fast, JIT-friendly
```

### Benchmarking

Use lde's profiler and jit debugger to try to improve performance.
