<div align="center">

<a href="https://lde.sh/">
	<img src="./assets/dist/lde-text-nospace.svg" alt="lde logo" width="256" />
</a>

---

[![Build+Test](https://github.com/lde-org/lde/actions/workflows/nightly.yml/badge.svg)](https://github.com/lde-org/lde/actions/workflows/nightly.yml) [![Latest Release](https://img.shields.io/github/v/release/lde-org/lde?labelColor=2d333b)](https://github.com/lde-org/lde/releases/latest) [![Discord](https://img.shields.io/discord/1473159418257604752?logo=discord&logoColor=white&label=Discord&labelColor=2d333b)](https://discord.gg/rHgp7DhkHm)

</div>

`lde` is a modern package manager and toolkit for Lua, written in Lua.

It includes a LuaJIT runtime for any operating system, a test runner, and the ability to compile your Lua programs into single executables users can run in **<1mB**. All of this alongside a package manager and package registry to easily share and reuse lua code, properly version locked and isolated to your individual projects.

To get started, [read the docs](https://lde.sh/docs/getting-started/introduction).

## Features

- Easy project creation with `lde new` and `lde init`
- Automatic local package management, avoid conflicting global installs
- `lde add --path <package>` - Install local dependencies (good for monorepos)
- `lde add --git <repo>` - Install git dependencies (supports monorepos)
- `lde run` - Runs your project's init file and installs dependencies
- `lde compile` - Turn your project into a single executable, easily distributable
- `lde test` - Run project tests with the built-in test framework, [`lde-test`](./packages/lde-test)
- `lde bundle` - Bundle your project into a single lua file
- `lde x` - Execute a project in another location, perfect for CLIs (alias: `ldx`)
- `lde tree` - View your dependencies at a glance
- `lde update` - Update your dependencies to their latest versions
- `lde publish` - Create a PR to add your package to [the registry](https://github.com/lde-org/registry)

## Installation

| OS      | Command                                       |
| ------- | --------------------------------------------- |
| Linux   | `curl -fsSL https://lde.sh/install \| sh` |
| Windows | `irm https://lde.sh/install.ps1 \| iex`   |

_To upgrade your `lde` version, simply run `lde upgrade`!_

## Quickstart

Create a project with dependencies..

```bash
lde new myproject && cd myproject
lde add hood --git https://github.com/codebycruz/hood
echo "print(require('hood'))" > ./src/init.lua
lde run
# Output: table: 0x7f53326fd030
```

Or run a repository's code in a single command!

```bash
ldx triangle --git https://github.com/codebycruz/hood
```

## How does lde compare to other tools?

See [this table](https://lde.sh#compare) for a comparison between some of the most common tools.
