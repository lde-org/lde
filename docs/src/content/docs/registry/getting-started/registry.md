---
title: Registry
order: 1
---

The [lde registry](/registry) is a public, entirely open source registry for lde packages.

## How it works

It takes inspiration from existing registries such as from [zed](https://zed.dev) and [vcpkg](https://vcpkg.io), as it is a simple repository currently hosted on GitHub: https://github.com/lde-org/registry

Packages are portfiles that link to their source git repositories, with a pinned commit hash.

## Publishing

You can publish by creating a pull request to add a portfile, which will be reviewed and manually accepted by moderators.

> [!NOTE]
> This is done manually to avoid issues with lde's early stages in terms of name squatting.

You can read more on the dedicated [Publishing](/docs/registry/guides/publish) page

## Updating

Updating packages is simple, just create a pull request to update the portfile.

## Automation

The key difference from lde's registry and existing ones, is that it is almost entirely automated.

Upon a successful manual review and merging of a package, ownership will be assigned to the PR creator, and any PRs from them that adjust the portfile will be automatically merged by a bot.
