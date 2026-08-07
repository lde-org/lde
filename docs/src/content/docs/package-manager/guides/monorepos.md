---
title: Monorepos
order: 3
---

# Monorepos

lde is built for monorepos - a single repository that holds many packages. The lde repository itself is a monorepo.

`lde.json` can live anywhere in the tree and sibling packages depend on each other through path dependencies.

Git dependencies can resolve to a package nested anywhere inside a repository, and `lde test` run from the repo root tests every package at once.

## Recommended layout

Any layout works, as lde discovers packages by scanning for `lde.json` files. But the `packages/` directory convention is the one lde itself uses:

```text
myrepo/
├── packages/
│   ├── utils/
│   │   ├── lde.json
│   │   └── src/
│   │       └── init.lua
│   ├── engine/
│   │   ├── lde.json
│   │   └── src/
│   │       └── init.lua
│   └── game/
│       ├── lde.json
│       ├── src/
│       │   └── init.lua
│       └── tests/
│           └── main.test.lua
```

Keeping each package under `packages/<name>/` keeps the root clean and makes sibling references predictable. This is of course not enforced upon you though.

## Sibling dependencies

Packages in the same repo depend on each other with path dependencies. From `packages/game/`:

```sh
lde add utils --path ../utils
```

or directly in `packages/game/lde.json`:

```jsonc
{
	"name": "game",
	"dependencies": {
		"utils": { "path": "../utils" },
		"engine": { "path": "../engine" }
	}
}
```

The dependency key is the require name (`require("utils")`), independent of where the package physically lives.

## Testing across packages

Run `lde test` from the repo root and lde runs every package that has a `tests/` directory, each with its own dependency tree and runtime:

```sh
lde test
```

Filters are globs, and in a multi-package run they apply per package — only matching test files run, in every package:

```sh
# Every package: only test files whose name contains "auth"
lde test "*auth*"

# Every package: only tests under unit/
lde test "unit/*"
```

Multiple filters combine with OR semantics. A file runs if it matches any of them. All flags from lde test work, like `--watch` and `--coverage`, from the root too.

To scope a command to one package from the root, use `-C`:

```sh
lde test -C packages/game
lde run -C packages/game
```

## Git dependencies from a monorepo

A git dependency doesn't have to live at the repository root. When you add a git dependency, lde clones the repository and searches it for a package whose `name` matches the dependency key no matter how deeply it is nested:

```sh
lde add utils --git https://github.com/your-org/myrepo
```

If the repository contains many packages, lde picks the one whose `name` matches, like cargo's git dependencies. A single repository can host any number of lde packages. The resolved commit is pinned into the lockfile, so the dependency stays reproducible.

lde itself is a monorepo, and it's used this way in the wild:

```sh
lde add lde-test --dev --git https://github.com/lde-org/lde
```

That resolves the `lde-test` package nested under `packages/lde-test/` in the lde repository.
