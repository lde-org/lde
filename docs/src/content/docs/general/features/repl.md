---
title: REPL
order: 0
---

# REPL

The `lde repl` command starts an interactive LuaJIT shell.

The shell runs in the lde environment. The `require()` function finds the project dependencies. `lde run` uses the same environment.

## To start the REPL

1. Open a terminal.
2. Go to the project directory.
3. Run this command:

```sh
lde repl
```

When you start the REPL in a package, lde does these steps:

1. Build the package.
2. Install the package dependencies.
3. Add `target/` to the module paths.

The prompt shows this information:

```
lde repl — LuaJIT interactive shell
Type exit() or press Ctrl+C to quit.

Project: my-package (/path/to/my-package)
> require("my-package.lib.helper")
= <table>
```

When you start the REPL outside a package, the shell opens in a plain LuaJIT state.

## To edit a line

The REPL has a built-in readline function. This function is written in pure Lua. It does not need external software.

The REPL supports these functions:

- Line editing.
- Command history (arrow keys).
- Syntax highlighting.

These functions operate on POSIX and Windows terminals.

## To complete a word

Press Tab after a prefix. The REPL completes variable and field names.

Completion covers globals and table fields, including dotted paths:

```
> json.e<Tab>      →  json.encode
```

`json.e` completes to `json.encode`.

## To enter a multi-line statement

When a statement is not complete, the prompt shows `...`. The REPL keeps the statement in a buffer until it is complete:

```
> local function greet(name)
>>   return "hello " .. name
>> end
> greet("world")
= "hello world"
```

Declarations stay in the shell between lines. `local function` and `const` declarations become globals. They stay available on the next line:

```
> const retries = 5
> retries += 1
> retries
= 6
```

## Results

The REPL shows the result of an expression. The result has the prefix `=`. The REPL shows tables with indentation. It detects circular references:

```
> { x = 1, nested = { y = 2 } }
= {
    x = 1,
    nested = {
      y = 2
    }
  }
```

## To exit

Do one of these actions:

- Run `exit()`.
- Run `quit()`.
- Press Ctrl+C.
- Press Ctrl+D.
