---
title: Coverage
order: 1
---

The concept of test coverage is to run your tests, and measure how much of your codebase was "covered" (executed) by your tests.

The thought is that with more coverage, more of your codebase will be bug-free.

This is why lde ships coverage out of the box.

## Usage

Simply pass the `--coverage` flag when running tests.

```sh
lde test --coverage
```

> [!WARNING]
> Tests will run slower with coverage enabled, as the JIT is disabled.

This will output a report of executed lines, total executable lines and a relative percentage to know which files are least tested, ignoring whitespace and dependencies.
