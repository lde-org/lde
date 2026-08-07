---
title: Moonscript Support
order: 2
---

# Moonscript Support

LDE runs programs that you write in [Moonscript](https://moonscript.org/). Moonscript is a language that compiles to Lua. You do not need to install the Moonscript compiler. You do not need a `build.lua` script. A package with `.moon` files in its `src/` directory runs with the normal commands: `lde run`, `ldx`, and `lde compile`.

## Quickstart

1. Create a directory for the project.
2. Create the file `lde.json` in this directory. Use this content:

```jsonc lde.json
{
	"name": "hello-moon",
	"version": "0.1.0"
}
```

3. Create the directory `src/`.
4. Create the file `src/init.moon`. Use this content:

```moonscript src/init.moon
greet = require("hello-moon.greet")
n = 40
print(greet("moon") .. " " .. tostring(n + 2))
```

5. Create the file `src/greet.moon`. Use this content:

```moonscript src/greet.moon
greet = (name) -> "hello " .. name
return greet
```

6. Run the command `lde run` from the project directory.

The output is:

```
hello, moon 42
```

The file `src/init.moon` is the entry point. This is the same as `src/init.lua` for packages that use Lua.

## A command line program

You can make a command line program with the field `bin`. Set the field to a `.moon` file:

```jsonc lde.json
{
	"name": "greet-cli",
	"version": "0.1.0",
	"bin": "main.moon"
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

### The build step compiles the Moonscript files

When the `src/` directory of a package contains `.moon` files, lde compiles them during the build step. It does not create a symbolic link to the source directory. Each `.moon` file becomes a `.lua` file in `target/<name>/`. The directory structure stays the same. Files that are not `.moon` files are copied without changes.

After the build, the package contains only Lua files. Running, testing, dependencies, and compilation use the normal process for Lua packages. This also applies to dependencies. LDE compiles a Moonscript dependency in the same way when it installs the dependency.

### LDE installs the compiler on demand

LDE uses the official Moonscript compiler. This compiler is not part of the lde binary. When lde finds a `.moon` file for the first time, it installs the compiler. It uses the same process as the command `ldx rocks:moonscript`. This gets the LuaRocks package `moonscript`. LDE stores the compiler in the global directory `~/.lde`. The first use downloads the compiler from the internet. On later runs, lde uses the stored copy. Later runs are fast. Projects that do not use Moonscript are not affected.

### Run a single file

You can compile and run a single Moonscript file without a package:

```sh
$ lde ./script.moon
```

## Rules and limitations

- You can mix `.moon` files and `.lua` files in the same package.
- Moonscript is sensitive to indentation. The first line of a `.moon` file must not be indented.
- The target is LuaJIT. LDE compiles the code to Lua 5.1. The code runs on the LDE runtime without extra runtime dependencies.
