---
title: Hot Reloading
order: 5
---

# Hot Reloading

`lde run --hot` watches your project's source files and reloads changed modules when you save without restarting the process. Globals, open handles, and everything your modules do once at load time survive the reload.

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

5. Change the greeting in `src/greet.lua` and save. lde drops the cached module, prints `Reloaded: hello-hot.greet`, and re-runs the entry point — the same process, the same state.

## --hot vs --watch

`lde run --watch` re-runs the entry point on file changes too, but it tears down the guest state and creates a fresh one every time. `--hot` keeps the state and only replaces the changed modules.

| | `--hot` | `--watch` |
|---|---|---|
| State | Same state, only changed modules are replaced | Fresh state each run (`_G`, `package.loaded`, globals) |
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
- **`--profile` / `--flamegraph` are not supported** with `--hot` or `--watch`.
- **Shell scripts** (`scripts` in `lde.json`) only work with `--watch`, not `--hot` — there's no module state to patch.
