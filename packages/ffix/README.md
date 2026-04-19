# ffix

This is a namespaced version of the `ffi` library for LuaJIT.

It works by parsing your C code and individually renaming types and symbols to be namespaced to an `ffix.context()`.

This solves the issue of ffi redefinition fears that are all too common with a large amount of ffi definitions in LuaJIT.

## Usage

```
lde add ffix --git https://github.com/lde-org/lde
```
