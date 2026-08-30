---
title: Introduction
order: 0
---

# Single File Apps

LDE gives you the ability to compile your lua program into single files.

## Bundle your program into a single lua file

Run this to bundle your project and all of its dependencies into a single .lua file

```sh
lde bundle
```

You can pass it options like `--bytecode` to bundle them into a bytecode file for faster startup.

## Bundle your program into a native executable

This option is very interesting if you want to give users access to an executable without needing lua on their system.

On Linux and macOS you will need `gcc` available on your machine. On Windows, lde downloads and sets up MinGW automatically.

```sh
lde compile
```

This will bundle into a single lua file and then compile an executable with the lde runtime built-in to execute it.

The lde executable itself is in fact just created with `lde compile`!
