<div align="center">

<a href="https://lualpm.com/">
	<img src="./assets/lpm-small-text-nospace.svg" alt="lpm logo" width="256" />
</a>

---

[![Build+Test](https://github.com/codebycruz/lpm/actions/workflows/nightly.yml/badge.svg)](https://github.com/codebycruz/lpm/actions/workflows/nightly.yml) [![Latest Release](https://img.shields.io/github/v/release/codebycruz/lpm?labelColor=2d333b)](https://github.com/codebycruz/lpm/releases/latest) [![Discord](https://img.shields.io/discord/1473159418257604752?logo=discord&logoColor=white&label=Discord&labelColor=2d333b)](https://discord.gg/rHgp7DhkHm)

</div>

`lpm` is a modern package manager and toolkit for Lua, written in Lua.

It includes a LuaJIT runtime for any operating system, a test runner, and the ability to compile your Lua programs into single executables users can run in **<1mB**. All of this alongside a package manager and package registry to easily share and reuse lua code, properly version locked and isolated to your individual projects.

To get started, [read the docs](https://lualpm.com/docs/getting-started/introduction).

## Features

- Easy project creation with `lpm new` and `lpm init`
- Automatic local package management, avoid conflicting global installs
- `lpm add --path <package>` - Install local dependencies (good for monorepos)
- `lpm add --git <repo>` - Install git dependencies (supports monorepos)
- `lpm run` - Runs your project's init file and installs dependencies
- `lpm compile` - Turn your project into a single executable, easily distributable
- `lpm test` - Run project tests with the built-in test framework, [`lpm-test`](./packages/lpm-test)
- `lpm bundle` - Bundle your project into a single lua file
- `lpm x` - Execute a project in another location, perfect for CLIs (alias: `lpx`)
- `lpm tree` - View your dependencies at a glance
- `lpm update` - Update your dependencies to their latest versions
- `lpm publish` - Create a PR to add your package to [the registry](https://github.com/codebycruz/lpm-registry)

## Installation

| OS      | Command                                       |
| ------- | --------------------------------------------- |
| Linux   | `curl -fsSL https://lualpm.com/install \| sh` |
| Windows | `irm https://lualpm.com/install.ps1 \| iex`   |

_To upgrade your `lpm` version, simply run `lpm upgrade`!_

## Quickstart

Create a project with dependencies..

```bash
lpm new myproject && cd myproject
lpm add hood --git https://github.com/codebycruz/hood
echo "print(require('hood'))" > ./src/init.lua
lpm run
# Output: table: 0x7f53326fd030
```

Or run a repository's code in a single command!

```bash
lpx triangle --git https://github.com/codebycruz/hood
```

## Comparison to LuaRocks and Lux

I made this to the best of my ability with limited information about LuaRocks and Lux.

If anyone has any corrections, please do submit a pull request.

|                       | lpm            | lux          | luarocks     |
| --------------------- | -------------- | ------------ | ------------ |
| Written in            | Lua            | Rust         | Teal         |
| Project format        | JSON           | TOML/Lua     | Lua          |
| Add/remove deps       | ✓              | ✓            | ❌           |
| Built-in test runner  | ✓ (lpm-test)   | ✓ (busted)   | ❌           |
| Ships with LuaJIT     | ✓              | ❌           | ❌           |
| Compile to executable | ✓              | ❌           | ❌           |
| Git deps              | ✓              | ✓            | ❌           |
| Registry deps         | ✓ (lpm)        | ✓ (luarocks) | ✓ (luarocks) |
| Custom Registry       | ✓              | ❌           | ✓            |
| Lockfile              | ✓              | ✓            | ✓            |
| Luarocks Support      | ❌ ([#53][53]) | ✓            | ✓            |
| Lua build scripts     | build.lua      | rockspec     | rockspec     |

[53]: https://github.com/codebycruz/lpm/issues/53
