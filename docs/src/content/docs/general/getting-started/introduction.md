---
title: Introduction
order: 0
---

# Introduction

lde is a package manager, runtime, test runner and bundler for Lua. It ships as a single executable with LuaJIT bundled in for you.

The days of fiddling with lua and luarocks setups are over.

Provide users a single binary without dependencies of your project with a simple `lde compile`!

## Getting Started

Create a new project with `lde new` (or `lde init` in an existing directory).

It'll first ask you what package name you'd want and if you want to write a library or a `blank` package.

For now, choose `blank`. Additionally, it will also ask what language you want to use.

Choose `lua` for now, but you choose and learn about [Teal](/docs/runtime/guides/teal) and [MoonScript](/docs/runtime/guides/moonscript) later.

```sh
lde new myproject && cd myproject
echo "print('Hello, world!')" > ./src/init.lua
```

## Adding Dependencies

Adding dependencies is as simple as `lde add`.

It supports the [lde registry](/registry), [luarocks](/docs/package-manager/dependencies/luarocks-support/), and direct git dependencies if you want to avoid a registry entirely.

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

Head to [Installation](/docs/general/getting-started/installation) to get lde on your machine, or jump straight to the [Quick Start](/docs/package-manager/getting-started/quick-start) if you've already installed it.
