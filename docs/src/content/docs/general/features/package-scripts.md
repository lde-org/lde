---
title: Package Scripts
order: 1
---

The lde.json file supports a "scripts" field that allows you to define custom scripts to run.

This is useful for:

1. Shortening repeated usecases
2. Running a package with `ldx` before running a file (ie, teal, luacheck)
3. Doing something other than running a file

## Example

```json lde.json
{
  "scripts": {
    "dev": "lde run ./src/dev.lua"
  }
}
```

## Running Scripts

You can run a script with `lde run <name>`.

> [!TIP]
> As a shorthand, lde supports `lde <name>` for script names that don't conflict with lde's built-in commands.
