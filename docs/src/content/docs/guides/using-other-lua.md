---
title: Alternate Lua Engines
order: 3
---

# Using an Alternate Lua Engine

By default, LDE ships with the [LDE Runtime](/docs/features/runtime) which is based on LuaJIT.

But LDE supports usage of other Lua Engines, such as Lua 5.4

To do this, edit your `lde.json` to provide which program to run instead of using LDE.

```json
{
	"name": "myproject",
	"engine": "lua5.4"
}
```

After this, `lde run` will try to use that engine you provided.

_This currently does NOT support running tests, which are integrated with the LDE runtime!_
