---
title: Searching Packages
order: 3
---

You can search for packages using `lde search`.

```bash
lde search <query>
```

This allows you to search both the [lde registry](/registry) and the luarocks registry simultaneously, weighing relevant results, and lde results, higher.

![search](/docs-assets/search.png)

The luarocks packages are differentiated by the rock emoji prefix.

## Installing

When running `lde search` outside of a package, interacting with the TUI and pressing enter on a package will `lde install` it.

This is useful for searching for binary packages.

## Adding Dependencies

When running `lde search` inside a package, interacting with the TUI and pressing enter on a package will `lde add` it.
