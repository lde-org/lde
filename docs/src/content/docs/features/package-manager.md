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

This can be automated with the `lde add` command. For git dependencies, do `lde add <name> --git <repo>` and for local dependencies, do `lde add --path <package>`.

## Removing a dependency

Simply remove the entry from your `lde.json`, or use `lde remove <name>`.

## Running your program with dependencies

You can use `lde install` to build all of your dependencies to a folder `./target/` inside of your project.

If you're just running a normal Lua project, you can simply use `lde run` which will configure lua automatically to resolve dependencies from your /target/ directory automatically.

By default, `lde run` will use the [LDE Runtime](/docs/features/runtime), which you can read about more on its dedicated page.
