---
title: Executing Packages
order: 3
---

# Tools

A concept of 'tools' exists in lde, wherein a package is simply used as a program. But anything can be a tool as long as it is intended to be run in its `./src/init.lua` file, including luarocks packages.

## lde x

You can run any package from git or a local path.

```bash
lde x triangle --git https://github.com/codebycruz/hood
```

For short, lde registers a `ldx` alias for `lde x`, so you can also run:

```bash
ldx triangle --git https://github.com/codebycruz/hood
```

This clones the hood repository, resolves the triangle package, and then instantly runs the package. You can do this with --path dependencies as well.

### Git shorthands

Instead of `--git <url>`, the common git hosts have shorthands that take the `owner/repo` form directly:

```bash
ldx gh:codebycruz/hood        # https://github.com/codebycruz/hood
ldx github:codebycruz/hood    # same repo, explicit prefix
ldx gitlab:owner/repo         # https://gitlab.com/owner/repo
ldx codeberg:owner/repo       # https://codeberg.org/owner/repo
```

They work anywhere a git source is accepted — `lde x`, `lde install`, and `lde add`:

```bash
lde install gh:codebycruz/hood
lde add gh:codebycruz/hood     # adds the git dep under the key "hood"
```

For a package inside a monorepo, the `@` form carries the package name, the same as the `[package-name]` positional of `--git`:

```bash
ldx gh:triangle@codebycruz/hood   # package "triangle" inside github.com/codebycruz/hood
lde add gh:triangle@codebycruz/hood  # adds the git dep under the key "triangle"
```

### Offline

Registry and luarocks lookups normally refresh their metadata on every run. If you're offline (or just want to avoid the network), pass `--offline`:

```bash
lde x triangle --offline
```

`--offline` resolves the package strictly from the local cache at `~/.lde` and fails with a clear error if it isn't cached yet — run it once online to populate the cache. Installed tools already run this way: `lde install` writes wrappers that invoke `lde x <name> --offline`.

## lde install

But this is quite tedious if you need to repeatedly run this tool, so you can install tools to your PATH.

```bash
lde install triangle --git https://github.com/codebycruz/hood
# Now you can run `triangle` from your terminal!
triangle
```

> [!WARNING]
> For luarocks packages that register their binaries under a different name, they will still be installed under the name of the package.
> Example: `lde install foobar` that intends to create a package called `baz` will still be installed under `foobar` by lde.

## lde uninstall

To remove previously installed tools, you can run:

```bash
lde uninstall triangle
```
