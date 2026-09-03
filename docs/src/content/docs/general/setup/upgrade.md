---
title: Upgrading lde
order: 0
---

To upgrade lde, simply run the following command:

```bash
lde upgrade
```

This will check if you're on the latest version, otherwise, it will download the latest release from GitHub and replace the currently running binary with it.

## Forcing an upgrade

If your install is broken in some way, or you want to reinstall, you can use --force to ensure the upgrade happens regardless.

```bash
lde upgrade --force
```

## Upgrading to a specific version


> [!WARNING]
> Versions prior to 0.10.0 will not work to be downgraded to, as they are not compatible with the current version of lde's zipped releases.

You can use the --version flag to specify a specific version to upgrade to, which is useful if you want to downgrade or upgrade to a specific pre-release.

```bash
lde upgrade --version=0.10.0
```

## Upgrading to nightly

You can upgrade to the latest nightly build (most recent build from GitHub)

> [!WARNING]
> Nightly builds still always have the test suite run before being published. But they may still be unstable.
> Use at your own risk.

```bash
lde upgrade --nightly
```
