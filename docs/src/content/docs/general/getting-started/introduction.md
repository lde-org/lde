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

Run `lde new` to create a new project.

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

You can use whatever language you want. We'll use **lua**.

## Adding Dependencies

Adding dependencies is as simple as `lde add`.

It supports the [lde registry](/registry), [luarocks](/docs/package-manager/getting-started/luarocks), and direct git dependencies if you want to avoid a registry entirely.

Dependencies are resolved locally to your project for easy access to lua without polluting your PATH, or needing some kind of virtual environment. (But they are cached and reused globally for performance and to save space)

```sh
lde add hood --git https://github.com/codebycruz/hood
lde add rocks:luasocket
```

## Running Your Project

We aren't just dealing with a package manager here. You want to be able to run your code..

Running `lde run` will run your project's entrypoint using the embedded LuaJIT engine.

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

How do we give it to our users? What about run it on a server?

Thankfully, lde can **compile** your code into a single executable, including all of its dependencies.

This can be done with `lde compile`, and the output executable will need no dependencies, not even lua.

## Next Steps

Head to [Installation](/docs/general/getting-started/installation) to get lde on your machine, or jump straight to [Scaffold a New Project](/docs/general/features/new-project) if you've already installed it.
