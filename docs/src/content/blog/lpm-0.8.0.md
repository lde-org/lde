---
title: Release v0.8.0
author: David Cruz
published: 2026-03-26
description: Adds LuaRocks dependency support, flat lockfile for transitive deps, a basic REPL, and more lpm-test utilities.
---

> Upgrade to the latest version with `lpm upgrade`!

## LuaRocks support

This is the big one. lpm can now install packages from the LuaRocks registry using the `luarocks` field in your `lpm.json`:

```json
{
  "dependencies": {
    "luafilesystem": { "luarocks": "luafilesystem" },
    "busted": { "luarocks": "busted" }
  }
}
```

You can also add them from the CLI:

```sh
lpm add rocks:luafilesystem
```

`lpx` and `lpm install` support it too:

```sh
lpx rocks:luacheck
lpm install rocks:busted
busted
```

![vid](/blog-assets/0.8.0/busted.gif)

If a package has a rockspec in a git repo, you can point to it manually with the `rockspec` field:

```json
{
  "dependencies": {
    "middleclass": {
      "git": "https://github.com/kikito/middleclass",
      "rockspec": "./rockspecs/middleclass-4.1.1-0.rockspec"
    }
  }
}
```

LuaRocks support includes C module compilation — lpm will download LuaJIT headers and compile native modules automatically. Platform-specific modules are handled too.

This is an initial implementation. Things may not work perfectly across all packages — if you run into issues, please [report them](https://github.com/codebycruz/lpm/issues).

## Archive dependencies

You can now install dependencies directly from a `.zip` or tarball URL:

```json
{
  "dependencies": {
    "foo": { "archive": "https://example.com/foo.zip" }
  }
}
```

## Flat lockfile for transitive dependencies

Previously, transitive dependencies weren't always tracked reliably. Now lpm stores all dependencies - direct and transitive - flat in a single lockfile. This is how it was always intended to work, and it makes installs more deterministic and conflict-free.

## Basic REPL

Running `lpm repl` drops you into an interactive Lua session with your project's dependencies available:

```sh
lpm repl
```

![vid](/blog-assets/0.8.0/repl.gif)

## New `lpm-test` utilities

A few more additions to the test framework:

```lua
test.skip()           -- unconditionally skip a test
test.skipIf(cond)     -- skip if condition is true
test.deepEqual(a, b)  -- deep equality check
test.match(str, pat)  -- pattern match assertion
```

Skipped tests are now printed separately in the output.
