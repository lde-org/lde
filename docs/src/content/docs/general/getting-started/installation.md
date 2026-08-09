---
title: Installation
order: 1
---

# Installation

Install lde using the command for your platform.

## Linux & macOS

```sh
curl -fsSL https://lde.sh/install | sh
```

## Windows

```powershell
irm https://lde.sh/install.ps1 | iex
```

## Verify

After installing, verify lde is available:

```sh
lde --version
# 0.10.0
```

When built from a git checkout, the version also includes the commit hash (`0.10.0-nightly+a1b2c3d`), which makes it easy to report which exact build you're running.
