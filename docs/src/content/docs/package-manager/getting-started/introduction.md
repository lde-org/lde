---
title: Introduction
order: 0
---

When creating a piece of software, chances are, you're not going to be writing everything from scratch. Even if you were, you would most likely want to modularize your code into reusable packages.

The job of a package manager is to be able to pull in external modules reproducibly and fast. This is made easy by lde. Simply `lde add` a dependency and they'll build on run.

> [!NOTE]
> Even if these are built locally, dependencies are cached globally as to reuse them across packages to save space. But they do not pollute your global lua installs.

## Adding a dependency

The easiest way to add a dependency is with the `lde add` command.

```bash
lde add <name>
```

> [!TIP]
> This supports luarocks packages as well, if you prefix `<name>` with `rocks:`, ie `rocks:luasocket`!

This will automatically add a field to your `lde.json`'s `dependencies` field.

```json
"dependencies": {
	"<name>": { "version": "0.9.1" }
}
```

By default, this will look for packages in the [lde registry](/registry).

### Git Dependencies

To add a dependency from a git repository, do:

```sh
lde add <name> --git <repo>
```

This supports nested packages, so if your git repository contains multiple lde packages, it will search for the specific package with the name `<name>` for monorepo support.

### Shorthands

Some shorthands are provided for common git hosts:

- `gh:`/`github:` (GitHub)
- `gitlab:` (GitLab)
- `codeberg:` (Codeberg)

Here's some example usage:

```sh
lde add gh:codebycruz/hood
lde add gitlab:codebycruz/hood
lde add codeberg:codebycruz/hood
```

These also support the monorepo form via this syntax:

```sh
lde add gh:name@codebycruz/hood
lde add gitlab:name@codebycruz/hood
lde add codeberg:name@codebycruz/hood
```

### Dev Dependencies

Sometimes dependencies are only needed for development, in the case of running tests, type checking, etc.

You can add dev dependencies by writing it to your `devDependencies` field instead of `dependencies`, or passing `--dev` to `lde add`.

```sh
lde add <name> --dev
```

## Removing a dependency

Simply remove the entry from your `lde.json`, or use `lde remove <name>`.

> [!TIP]
> This works for dev dependencies as well.

## Installing dependencies

This should be done for you automatically whenever you `lde run` or `lde ./file.lua`.

But, in the case of simply packaging lua for an external runtime (like Love2D, Neovim, etc.), the `lde sync` command is provided.

### Reproduction

On first install, dependencies will be written to a `lde.lock` file with commit information to keep track of the exact version installed, which is useful for floating dependencies, like git dependencies.

You'll want to commit this file to your repo if you're writing an application, libraries should gitignore it as it will not be used.

```sh
lde sync
lde sync --locked      # install from the lockfile only
lde sync --production  # skip dev dependencies
```

## Production Installs

You can use `lde sync --production` to install only production dependencies, skipping dev dependencies.

The same flag exists on `lde install` for when you want to install the project's dependencies without dev dependencies:

```sh
lde install --production
```
