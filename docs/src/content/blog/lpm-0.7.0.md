---
title: Release v0.7.0
author: David Cruz
published: 2026-03-14
description: Launches the lpm package registry with lpm publish, adds lockfile support for reproducible installs, and introduces registry dependencies via lpm add.
---

> Upgrade to the latest version with `lpm upgrade`!

## LPM Registry

lpm now has its own package registry you can already contribute to. It takes the vcpkg approach of being a simple GitHub repo, so authentication and file hosting are handled by GitHub: [lde-org/lde-registry](https://github.com/lde-org/lde-registry)

Publishing is as simple as running `lpm publish` from your package directory. It reads your git remote, branch, and current commit, builds the portfile automatically, and opens your browser straight to a GitHub PR with everything pre-filled.

Registry dependencies are not yet supported in `lpx`, but there are no packages that would use it anyway for now.

You can browse available packages at [lde.sh/registry](https://lde.sh/registry).

## Lockfiles

Lockfiles are now implemented. They're largely a convenience over manually pinning a git dependency, but they also enable reproducible installs without any extra effort. By default, `lpm-lock.json` is gitignored. The format is a simple, readable JSON file. A custom binary format may come later.

## Registry dependencies

With the registry comes registry dependencies. Run `lpm add <name>` and it just works. The package is resolved to a git dependency pinned to the matching commit and stored in your lockfile.

You can also declare them manually in `lpm.json`:

```json
"dependencies": {
  "hood": { "version": "0.1.0" }
}
```

To request a specific version:

```sh
lpm add whatever@0.1.0
# or
lpm add whatever --version 0.1.0
```

Use `lpm update` to upgrade registry dependencies to the latest compatible version (minor or patch updates only; major version bumps are never applied automatically).

Try it out:

```sh
lpm add hood
```

## Bug fixes

- Fixed a stale-dependency issue where packages with build scripts were not being refreshed on reinstall. lpm was incorrectly assuming the dependency was already up to date, requiring users to manually delete their `target/` folder to force a rebuild. Build scripts now always run and their output is always refreshed.
