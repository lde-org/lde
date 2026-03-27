---
title: Tools
order: 6
---

# Tools

LDE has support for running packages as tools, which is useful for command line applications, build tools, and more.

Any package is automatically a 'tool', simply by the nature of packages all having init.lua as their entrypoint.

## lde x

You can run any package from git or a local path.

```bash
lde x triangle --git https://github.com/codebycruz/hood
```

For short, lde registers a `lpx` alias for `lde x`, so you can also run:

```bash
lpx triangle --git https://github.com/codebycruz/hood
```

This clones the hood repository, resolves the triangle package, and then instantly runs the package. You can do this with --path dependencies as well.

## lde install

But this is quite tedious if you need to repeatedly run this tool, so you can install tools to your PATH.

```bash
lde install triangle --git https://github.com/codebycruz/hood
# Now you can run `triangle` from your terminal!
triangle
```

## lde uninstall

To remove previously installed tools, you can run:

```bash
lde uninstall triangle
```
