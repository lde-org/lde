---
title: Shared Libraries
order: 5
---

`lde compile --shared` builds your package into a shared library (`.so` on Linux and FreeBSD, `.dll` on Windows, `.dylib` on macOS) that C, C++, or any other language with a C FFI can load.

You can use it to write a number of useful things you'd usually never be able to use a scripting language for:

- Write a plugin for a native application, like VST, or OBS.
- Extensions for games like Garry's Mod and engines like Godot.
- Export your library to be used by native applications like C, C++ and Rust, with minimal\* overhead.

> [!NOTE]
> \*The overhead measured ranges from ~18 to ~80ns per-call depending on the arguments and any casting that needs to be done when calling the function. If you want to minimize this you could design your API to minimize calls, but it is still quite workable.

```sh
lde compile --shared
lde compile --shared --target windows-x86-64 # works with cross compilation
```

## Exporting functions

Put a `---@export "C"` annotation directly above a `local function` to export it as a C symbol:

```lua title="src/init.lua"
---@export "C" fn(a: u32, b: u32): u32
local function add(a, b)
	return a + b
end

---@export "C" fn(name: string): string
local function greet(name)
	return "hello " .. name
end
```

> [!TIP]
> `fun(...)` (LuaCATS) and `function(...)` are accepted as spellings of `fn(...)`.

That library exports these C functions:

```c
uint32_t add(uint32_t a, uint32_t b);
const char* greet(const char* name);
```

> [!TIP]
> You can provide an export name to override the default symbol name: `---@export "C" my_add fn(a: u32, b: u32): u32` exports the function under `my_add`.

## Limitations

- Variadic functions cannot be exported.
- Exports may live in any module of your package. The entry point has to `require` that module.

> [!WARNING]
> Lua is still single threaded. Do not call into exported functions from multiple threads at once.

### Hosts with their own Lua

The library carries its own LuaJIT, and the host may have a Lua of its own (Garry's Mod, a Lua 5.4 host). The two never mix:

- The library's internal calls always go to its own LuaJIT, whatever the host loaded first.
- The library's `lua_*` are exported, but a host loads the library locally, so the host's own lookups never find them.
- `ffi.C.lua_*` inside the library is ambiguous: it finds the host's Lua when the host loaded it globally, and the library's own LuaJIT otherwise. Don't rely on it.
- Use [lua-sys](https://github.com/lde-org/lua-sys) for either side: `require("lua-sys"):lde()` is the library's own LuaJIT (new states, sandboxes), and `:vendored("luajit")` / `:vendored("lua54")` / `:open(path)` is the host's Lua (e.g. Garry's Mod's `lua_shared`). Both give raw C API bindings and high-level states.

## Types

Only these types are allowed:

| Annotation                         | C type               | Lua value received                                                       | Lua value to return                    |
| ---------------------------------- | -------------------- | ------------------------------------------------------------------------ | -------------------------------------- |
| `bool`                             | `bool`               | boolean                                                                  | any (truthiness)                       |
| `i8` `i16` `i32` (`int8_t` ...)    | `int8_t` ...         | number                                                                   | number                                 |
| `u8` `u16` `u32` (`uint8_t` ...)   | `uint8_t` ...        | number                                                                   | number                                 |
| `i64` `u64` (`int64_t` `uint64_t`) | `int64_t` `uint64_t` | number, or an `int64_t`/`uint64_t` cdata when the value is outside ±2^53 | number or 64-bit integer cdata         |
| `f32` `f64` (`float` `double`)     | `float` `double`     | number                                                                   | number                                 |
| `string`                           | `const char*`        | Lua string (a copy) or `nil` for `NULL`                                  | string, or `nil` for `NULL`            |
| `ptr` (`void*`)                    | `void*`              | lightuserdata (`ffi.cast("T*", p)` to use it)                            | lightuserdata, pointer cdata, or `nil` |
| `void`                             | `void`               |                                                                          | return type only                       |

A returned string stays valid until the next call of the same function.

## Runtime behavior

- Loading your library executes your `init.lua` so you can initialize your library and actually export entrypoints, so keep your entrypoint minimal and lazy to avoid unnecessary work.

- If an exported function raises an error, lde prints the error and its traceback to stderr and aborts the process.

> [!TIP]
> You should ideally `pcall` and provide a fallback value for exported functions so their failure doesn't crash the process.

> [!WARNING]
> Exported functions may be re-entered: your Lua code can call a C function through the FFI that calls an export of the same library again. LuaJIT cannot re-enter a Lua state from a JIT-compiled FFI call, and the process crashes. Put each FFI call that can re-enter in its own small function and turn the JIT off for that function. Only code paths that reach that call stay interpreted; everything else is still compiled:
>
> ```lua
> local function callHost(callback, value) return callback(value) end
> jit.off(callHost)
> ```
>
> `jit.off` on the exported function is not enough when the FFI call happens in a function it calls, and it also stops the JIT for the export's own loops.
