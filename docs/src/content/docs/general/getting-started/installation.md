---
title: Installation
order: 1
---

Install lde using the command for your platform.

## Linux & macOS

```sh
curl -fsSL https://lde.sh/install | sh
```

## Windows

```powershell
irm https://lde.sh/install.ps1 | iex
```

## Manual Installation

If you for whatever reason want to install it manually:
1. Download it from [Github Releases](https://github.com/lde-org/lde/releases) and unzip
2. Run `lde --setup` on the binary
3. Ideally place it in `~/.lde/lde` but this is not required. It will still work and support self upgrades

## Verify

After installing, verify lde is available:

```sh
lde --version
```

When built from a git checkout, the version also includes the commit hash (`0.10.0-nightly+a1b2c3d`), which makes it easy to report which exact build you're running.

## Upgrading

To upgrade lde, run `lde upgrade` to upgrade to the latest fixed release.

More details can be found in the [upgrading guide](/docs/general/setup/upgrade).
