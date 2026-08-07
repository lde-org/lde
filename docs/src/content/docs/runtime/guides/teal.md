---
title: Teal Support
order: 1
---

# Teal Support

LDE runs programs that you write in Teal. Teal is a typed dialect of Lua. You do not need to install the Teal compiler. You do not need a `build.lua` script. A package with `.tl` files in its `src/` directory runs with the normal commands: `lde run`, `ldx`, and `lde compile`.

## Quickstart

1. Create a directory for the project.
2. Create the file `lde.json` in this directory. Use this content:

```jsonc lde.json
{
	"name": "hello-teal",
	"version": "0.1.0"
}
```

3. Create the directory `src/`.
4. Create the file `src/init.tl`. Use this content:

```lua src/init.tl
local greet = require("hello-teal.greet")

local count: integer = 41
print(greet("world") .. " — " .. tostring(count + 1))
```

5. Create the file `src/greet.tl`. Use this content:

```lua src/greet.tl
local function greet(name: string): string
	return "hello, " .. name
end

return greet
```

6. Run the command `lde run` from the project directory.

The output is:

```
hello, world — 42
```

The file `src/init.tl` is the entry point. This is the same as `src/init.lua` for packages that use Lua.

## A command line program

You can make a command line program with the field `bin`. Set the field to a `.tl` file:

```jsonc lde.json
{
	"name": "greet-cli",
	"version": "0.1.0",
	"bin": "main.tl"
}
```

Run these commands from the project directory:

```sh
$ lde run
$ lde x greet-cli --path .
$ lde compile
```

The command `lde compile` creates a standalone executable file.

## How it works

### The build step compiles the Teal files

When the `src/` directory of a package contains `.tl` files, lde compiles them during the build step. It does not create a symbolic link to the source directory. Each `.tl` file becomes a `.lua` file in `target/<name>/`. The directory structure stays the same. Files that are not `.tl` files are copied without changes.

After the build, the package contains only Lua files. Running, testing, dependencies, and compilation use the normal process for Lua packages. This also applies to dependencies. LDE compiles a Teal dependency in the same way when it installs the dependency.

### LDE installs the compiler on demand

LDE uses the official Teal compiler (`tl`). This compiler is not part of the lde binary. When lde finds a `.tl` file for the first time, it installs the compiler. It uses the same process as the command `ldx rocks:tl`. This gets the LuaRocks package `tl`. LDE stores the compiler in the global directory `~/.lde`. The first use downloads the compiler from the internet. On later runs, lde uses the stored copy. Later runs are fast. Projects that do not use Teal are not affected.

### Run a single file

You can compile and run a single Teal file without a package:

```sh
$ lde ./script.tl
```

## Rules and limitations

- You can mix `.tl` files and `.lua` files in the same package.
- Type errors do not stop the program. LDE checks the types during compilation. A type error gives a warning. The program still runs. Use the command `tl check` for strict type checking.
- The target is LuaJIT. LDE compiles the code to Lua 5.1. The code runs on the LDE runtime without extra runtime dependencies.
- `.d.tl` files contain type declarations for Lua modules. The compiler uses these files. They do not produce runtime output.
