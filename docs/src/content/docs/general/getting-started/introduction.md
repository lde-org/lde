---
title: Introduction
order: 0
---

# Introduction

[lde](https://lde.sh) is a small and fast package manager, runtime, test runner and compiler for lua projects.

## Why lde?

- **It already works with your projects**. Just run `ldx rocks:tl` and `lde add rocks:luasocket`
- You're on windows and want lua on your system without setting up a full C toolchain.
- It works with your language. `lde ./foo.tl` and `lde ./foo.moon` just work.
- You want to ship a single binary to run your code to users without them needing lua.

## Getting Started

Run `lde new` to create a new project. It will 

```sh
~> lde new
? Project type
> blank   A basic hello world app
  library A module other projects can require()
```

Select **blank** for now.

```
? Language
> lua  Your typical lua project
  moonscript  A dynamically typed whitespace based language
  teal  Typed lua with type checking support
```

You can use whatever language you want. We'll use **lua**, of course.

## Adding Dependencies

Adding dependencies is as simple as `lde add` inside of your project

Dependencies are stored in a global cache for performance and space conservation, but they are symlinked into your local project as to not pollute your PATH.

You can also add dev dependencies (dependencies only needed for development) using `--dev`

### Git

You can add dependencies directly from git repositories using the `--git` flag, or the shorthands `gh:`, `codeberg:`, etc.

```sh
lde add hood --git https://github.com/bycruz/hood
# or use this for short:
lde add gh:bycruz/hood
```

### Registry

The [lde registry](/registry) is a centralized place to find and install dependencies, it allows easy discovery of dependencies with proper versioning.

```sh
lde add process
```

You can also add [luarocks](/docs/package-manager/getting-started/luarocks) packages this way with the `rocks:` prefix.

```sh
lde add rocks:luasocket
```

## Running Your Project

Running `lde run` will run your project's entrypoint (`./src/init.lua`) using the embedded LuaJIT engine.

```sh
lde run
# 'Hello, world!' is printed to the console
```

## Running Lua Tools

Run any remote tool easily with `ldx`!

```sh
ldx cowsay hi
```

```text
 ----
< hi >
 ----
       \   ^__^
        \  (oo)\_______
           (__)\       )\/\
               ||----w |
               ||     ||
```

This is the equivalent of manually installing the package, then going into the directory and running `lde run`.

## Test Your Code

If you can run your code with lde, you should be able to test that it works.

That's why lde ships with a minimal built-in test framework, known as `lde-test`.

```lua tests/example.test.lua
local test = require('lde-test')

test.it("should add numbers", function()
	test.equal(2, 2)
end)

test.it("should not be equal", function()
	test.notEqual(2, 3)
end)
```

Simply write this file, and then run `lde test` to see the results.

You can also get [test coverage](/docs/test-runner/getting-started/test-runner/) to ensure you're testing your full codebase with `lde test --coverage`.

## Compile Your Code

Now, we can add dependencies, run and even test our code. But this is all pointless if our code stays on our machine!

This is why you can [compile into a single executable](/docs/bundler/getting-started/compiling) without any dependencies, not even on lua.

```sh
lde compile
```

## Next Steps

1. [Download lde](/download) if you haven't already.
2. Take a look at the list of guides for using lde in your favorite environments!
