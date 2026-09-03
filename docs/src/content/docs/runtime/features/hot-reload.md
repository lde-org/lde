---
title: Hot Reloading
order: 5
---

# Hot Reloading

The concept of hot reloading is popular for rapid development where you want your code to update as you change it, while preserving things like open file handles, web servers, etc.

You don't want your entire website to reload whenever you edit your helper function.

This is why lde ships hot reloading via `lde --hot`, which watches your src tree, and patches in only changed files.

> [!WARNING]
> Obviously, if you change the init.lua file, it will trigger a full reload.

## Quickstart

1. Create a project and cd into it:

```sh
lde new ./hello-hot
```

2. Replace `src/init.lua`:

```lua src/init.lua
local greet = require("hello-hot.greet")
print(greet("world"))
```

3. Make `src/greet.lua`:

```lua src/greet.lua
return function(name)
	return "hello, " .. name
end
```

4. Run it:

```sh
lde run --hot
```

5. Change the greeting in `src/greet.lua` and save.

## --hot vs --watch

`lde run --watch` re-runs the entry point on file changes too, but it tears down the guest state and creates a fresh one every time. `--hot` keeps the state and only replaces the changed modules.

| | `--hot` | `--watch` |
|---|---|---|
| State | Same state, only changed modules are replaced | Fully re-runs the main entrypoint |
| Reload | `package.loaded` entries dropped, entry re-runs | Entire guest state recreated |
| Best for | Long-running apps that keep connections, caches, or loaded C modules | Anything that wants a guaranteed clean restart |

## Outside a package

`--hot` works for loose scripts too:

```sh
lde ./test.lua --hot
```

The current directory is watched and `require()` caches are patched the same way.

## Limitations

- **JIT is disabled while watching.** Hooks only fire on interpreted code, so the watched session runs slower than plain `lde run`.
- **Blocking C calls can't be interrupted.** A module stuck in `io.read()`, `socket:receive()`, or similar won't notice a change until the call returns.
