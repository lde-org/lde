<div align="center">

<a href="https://lde.sh/">
	<img src="./assets/dist/lde-text-nospace.svg" alt="lde logo" width="256" />
</a>

---

[![Build+Test](https://github.com/lde-org/lde/actions/workflows/nightly.yml/badge.svg)](https://github.com/lde-org/lde/actions/workflows/nightly.yml) [![Latest Release](https://img.shields.io/github/v/release/lde-org/lde?labelColor=2d333b)](https://github.com/lde-org/lde/releases/latest) [![Discord](https://img.shields.io/discord/1473159418257604752?logo=discord&logoColor=white&label=Discord&labelColor=2d333b)](https://lde.sh/discord)

</div>

`lde` is a modern package manager and toolkit for Lua, written in Lua.

It bundles a LuaJIT runtime, a test runner, and a compiler that turns your Lua programs into single executables <**1mB** alongside a package registry with proper version locking and project-local isolation.

To get started, [read the docs](https://lde.sh/docs/general/getting-started/introduction).

## Features

- `lde new` / `lde init` — Scaffold a new project
- `lde run` — Run your project, installing dependencies automatically
- `lde test` — Run tests with the built-in [`lde-test`](./packages/lde-test) framework
- `lde compile` — Compile your project into a single distributable executable
- `lde bundle` — Bundle your project into a single Lua file
- `lde add` — Add dependencies from a path, git repo, or the registry
- `lde x` / `ldx` — Execute a remote project directly, great for CLIs
- `lde tree` — Visualize your dependency graph
- `lde update` — Update dependencies to their latest versions
- `lde publish` — Submit your package to [the registry](https://github.com/lde-org/registry)

## Platform Support

| OS      | Architecture  |
| ------- | ------------- |
| Linux   | x86-64, ARM64 |
| macOS   | x86-64, ARM64 |
| Windows | x86-64, ARM64 |
| Android | ARM64         |

## Installation

| OS            | Command                                   |
| ------------- | ----------------------------------------- |
| Linux & macOS | `curl -fsSL https://lde.sh/install \| sh` |
| Windows       | `irm https://lde.sh/install.ps1 \| iex`   |

_Already installed? Run `lde upgrade` to update._

## Quickstart

```bash
lde new myproject && cd myproject
lde add hood --git https://github.com/codebycruz/hood
echo "print(require('hood'))" > ./src/init.lua
lde run
# Output: table: 0x7f53326fd030
```

Or run a remote project in one command:

```bash
ldx triangle --git https://github.com/codebycruz/hood
```

## How does lde compare to other tools?

See [this table](https://lde.sh#compare) for a comparison with other common tools.
