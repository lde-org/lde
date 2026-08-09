---
title: Package Manager
order: 1
---

# Package Manager

The central feature of lde is the package manager. It allows you to add dependencies to your project and installs them to a folder local to your project which lua's require() can resolve to.

## Adding a dependency

You can add a dependency by adding a field to your `lde.json` file.

An example list of dependencies:

```json
"dependencies": {
	"hood": { "path": "../hood" },
	"lde-test": { "git": "https://github.com/lde-org/lde" },
}
```

Git dependencies are cloned with `--recurse-submodules`, so any submodules in the repository are automatically initialized and checked out.

This can be automated with the `lde add` command. For git dependencies, do `lde add <name> --git <repo>` and for local dependencies, do `lde add --path <package>`.

## Removing a dependency

Simply remove the entry from your `lde.json`, or use `lde remove <name>`.

## Installing dependencies

Use `lde sync` to build all of your dependencies into a `./target/` folder inside of your project. It installs from the lockfile when possible, and `--locked` installs strictly from the lockfile (refusing to drift from it). `--production` skips dev dependencies.

```sh
lde sync
lde sync --locked      # install from the lockfile only
lde sync --production  # skip dev dependencies
```

If you're just running a normal Lua project, you can simply use `lde run` which will configure lua automatically to resolve dependencies from your /target/ directory automatically.

By default, `lde run` will use the [LDE Runtime](/docs/runtime/getting-started/runtime), which you can read about more on its dedicated page.
