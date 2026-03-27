---
title: Registry
order: 7
---

# Registry

LDE has its own custom package registry. This means you can get packages via `lde add <name>` and publish them with `lde publish`.

It is hosted purely on GitHub, so no files or binaries are hosted, it just acts as a bridge to hosted git repositories, with version pinning that abides to semver.

## Adding a dependency

You can use `lde add <name>` to add a dependency to an lde registry package. This will resolve the latest version of the package, pin it to the git commit, and add it to your lockfile.

To add it with a specific version, you can use `lde add <name>@<version>` or `lde add <name> --version <version>`.

## Updating dependencies

Use `lde update` to update registry dependencies to the latest compatible version (minor or patch updates only; major version bumps are never applied automatically).

## Publishing a package

Publishing a package is as simple as creating a pull request to the [lde-registry](https://github.com/lde-org/registry) repository with a single JSON file.

This is simplified with a single `lde publish` command which automatically opens your browser to a URL with the necessary info pre-filled to make a pull request.
