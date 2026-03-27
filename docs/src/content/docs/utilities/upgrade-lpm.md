---
title: Upgrading LDE
order: 1
---

# Upgrading LDE

To upgrade lde, simply run the following command:

```bash
lde upgrade
```

This will check if you're on the latest version, otherwise, it will download the latest release from GitHub and replace the running binary at ~/.lde/lde with it.

## Forcing an upgrade

If your install is broken in some way, or you want to reinstall, you can use --force to ensure the upgrade happens regardless.

```bash
lde upgrade --force
```

## Upgrading to a specific version

You can use the --version flag to specify a specific version to upgrade to, which is useful if you want to downgrade or upgrade to a specific pre-release.

```bash
lde upgrade --version=0.6.0
```

## Upgrading to Nightly

You can upgrade to the latest nightly build (most recent build from GitHub)

```bash
lde upgrade --nightly
```

Be wary it may be unstable! But also enjoy the new features a little early!
