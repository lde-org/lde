---
title: Registry
order: 1
---

The [lde registry](/registry) is a public, entirely open source registry for lde packages.

## How it works

It takes inspiration from existing registries such as from [zed](https://zed.dev) and [vcpkg](https://vcpkg.io), as it is a simple repository currently hosted on GitHub: https://github.com/lde-org/registry

Packages are portfiles that link to their source git repositories, with a pinned commit hash.

## Publishing

Sign in once with `lde login`, then run `lde publish` inside your package. It
creates a pull request for you. A first-time package is reviewed by a moderator;
updates from the recorded owner are approved and merged automatically.

You can read more on the dedicated [Publishing](/docs/registry/guides/publish) page

## Updating

Bump the version in `lde.json` and run `lde publish` again. Existing versions are
immutable; a new version may point at a different git repository or branch.

## Automation

The key difference from lde's registry and existing ones, is that it is almost entirely automated.

Upon a successful manual review and merging of a package, ownership will be assigned to the PR creator, and any PRs from them that adjust the portfile will be automatically merged by a bot.
