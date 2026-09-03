---
title: LuaRocks
order: 1
---

[LuaRocks](https://luarocks.org) is supported out of the box by lde and 100% backwards compatibility is intended.

## Installing a luarocks package

Simply prepend `rocks:` to add a luarocks dependency the same way you would an lde dependency!

```sh
lde add rocks:luasocket
```

## Installing a luarocks tool

Same thing here!

```sh
lde install rocks:busted
```

## Compatibility

If you have any issues with compatibility, please do [make an issue](https://github.com/lde-org/lde/issues).
