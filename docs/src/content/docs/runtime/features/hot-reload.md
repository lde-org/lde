---
title: Hot Reloading
order: 5
---

The concept of hot reloading is popular for rapid development where you want your code to update as you change it, while preserving things like open file handles, web servers, etc.

You don't want your entire website to reload whenever you edit your helper function.

This is why lde ships hot reloading via `lde run --hot`, which watches your src tree, and patches in only changed files.

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

## `--hot` vs `--watch`

The difference between these two is simple.

`--watch` re-runs your main entrypoint on *any* file changing, even a single helper file.
`--hot` only replaces the changed modules.

> [!NOTE]
> For example, if you're running a web server, the result of `require("that.module")` changes, but your program won't re-run.

## Outside a package

`--hot` works for loose scripts too:

```sh
lde ./test.lua --hot
```

The current directory is watched and `require()` caches are patched the same way.

## `package.hot`

This table is added to the `package` library only under `--hot` runs.

It can be used to register callbacks that run and are passed the module path whenever a file is hotreloaded.

```lua
if package.hot then
	package.hot.accept(|m| -> print("module reloaded", m))
end
```

The `m` here is the module's `require()` path.

It runs *before* your entrypoint runs, but *after* lde rebuilds your package (build.lua runs, if exists)

> [!TIP]
> This is useful for maintaining handles to things across re-runs like file handles, sockets, for web servers.

### `package.hot.poll()`

This function exists to pump the hotreloading loader, so that even in entirely blocking code, such as an event loop doing while true do end, you can still support hotreloading.

> [!TIP]
> This can and should be used by libraries to support hotreloading out of the box.

```lua
while running do
	handleEvents()
	if package.hot then package.hot.poll() end
end
```

## Limitations

- A program that blocks will not reload. For example, just a `while true do end` loop will block forever as control is never relinquished to lde. You can fix this with `package.hot.poll()` as seen above.
